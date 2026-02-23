import Foundation

/// Orchestrates the 5-phase install flow:
/// welcome -> selection -> summary -> install -> post-summary.
struct Installer {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner
    var backup: Backup
    let dryRun: Bool
    let registry: TechPackRegistry

    private var installedItems: [String] = []
    private var skippedItems: [String] = []

    init(
        environment: Environment,
        output: CLIOutput,
        shell: ShellRunner,
        backup: Backup = Backup(),
        dryRun: Bool,
        registry: TechPackRegistry = .shared
    ) {
        self.environment = environment
        self.output = output
        self.shell = shell
        self.backup = backup
        self.dryRun = dryRun
        self.registry = registry
    }

    // MARK: - Phase 1: Welcome

    mutating func phaseWelcome() throws {
        output.header("My Claude Setup")
        output.plain("")
        output.plain("  Configure Claude Code with MCP servers, plugins,")
        output.plain("  skills, and hooks for development.")
        output.plain("")

        // System checks
        #if !os(macOS)
        output.error("This tool requires macOS.")
        throw MCSError.invalidConfiguration("Unsupported platform")
        #endif

        if ProcessInfo.processInfo.environment["USER"] == "root" || getuid() == 0 {
            output.error("Do not run this tool as root.")
            throw MCSError.invalidConfiguration("Running as root")
        }

        output.info("Detected macOS on \(environment.architecture.rawValue)")

        // Check Xcode CLT
        let xcodeResult = shell.run("/usr/bin/xcode-select", arguments: ["-p"])
        if xcodeResult.succeeded {
            output.info("Xcode Command Line Tools: installed")
        } else {
            output.warn("Xcode Command Line Tools not found.")
            output.plain("  Install them with: xcode-select --install")
            output.plain("  Then re-run this tool.")
            throw MCSError.dependencyMissing("Xcode Command Line Tools")
        }

        // Check Homebrew (required for dependency installation)
        let brew = Homebrew(shell: shell, environment: environment)
        if brew.isInstalled {
            output.info("Homebrew: installed")
        } else {
            output.warn("Homebrew is required but not installed.")
            output.plain("")
            output.plain("  Install it with:")
            output.plain("    /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")
            output.plain("")
            output.plain("  Then re-run: mcs install")
            throw MCSError.dependencyMissing("Homebrew")
        }

        // Migrate old manifest file name if present
        if environment.migrateManifestIfNeeded() {
            output.dimmed("Migrated .setup-manifest → .mcs-manifest")
        }

        output.plain("")
        output.info("Required dependencies are auto-resolved based on your choices.")
    }

    // MARK: - Phase 2: Selection

    mutating func phaseSelection(
        installAll: Bool,
        packName: String?
    ) -> SelectionState {
        var state = SelectionState()

        let allPacks = registry.availablePacks
        let allComponents = registry.allPackComponents

        if installAll {
            state.selectAllCore(from: allComponents)
            for pack in allPacks {
                state.selectPack(
                    pack.identifier,
                    coreComponents: [],
                    packComponents: pack.components
                )
            }
            return state
        }

        if let packName {
            if let pack = registry.pack(for: packName) {
                state.selectPack(
                    packName,
                    coreComponents: [],
                    packComponents: pack.components
                )
                output.info("Selected tech pack: \(pack.displayName)")
            } else {
                output.warn("Unknown tech pack: \(packName)")
                if !allPacks.isEmpty {
                    output.plain("  Available packs: \(allPacks.map(\.identifier).joined(separator: ", "))")
                }
            }
            return state
        }

        // Interactive: show only external pack components for selection
        if allPacks.isEmpty {
            output.info("No packs registered. Use 'mcs pack add <url>' to add tech packs.")
            return state
        }

        output.header("Component Selection")

        var numberToComponentIDs: [Int: [String]] = [:]
        var number = 1
        var groups: [SelectableGroup] = []

        for pack in allPacks {
            var items: [SelectableItem] = []
            for component in pack.components {
                items.append(SelectableItem(
                    number: number,
                    name: component.displayName,
                    description: component.description,
                    isSelected: true
                ))
                numberToComponentIDs[number] = [component.id]
                number += 1
            }
            if !items.isEmpty {
                groups.append(SelectableGroup(
                    title: pack.displayName,
                    items: items,
                    requiredItems: []
                ))
            }
        }

        let selectedNumbers = output.multiSelect(groups: &groups)

        for (num, componentIDs) in numberToComponentIDs {
            if selectedNumbers.contains(num) {
                for id in componentIDs {
                    state.select(id)
                }
            }
        }

        return state
    }

    // MARK: - Phase 3: Summary

    func phaseSummary(
        plan: DependencyResolver.ResolvedPlan,
        state: SelectionState
    ) -> Bool {
        output.header("Installation Summary")

        let grouped = Dictionary(grouping: plan.orderedComponents) { $0.type }
        let displayOrder: [ComponentType] = [
            .brewPackage, .mcpServer, .plugin, .skill, .command, .hookFile, .configuration,
        ]

        var hasContent = false
        for type in displayOrder {
            guard let components = grouped[type], !components.isEmpty else { continue }
            hasContent = true
            output.plain("")
            output.sectionHeader("\(type.rawValue)")
            for component in components {
                let autoAdded = plan.addedDependencies.contains(where: { $0.id == component.id })
                let suffix = autoAdded ? " (auto-resolved)" : ""
                output.plain("    + \(component.displayName)\(suffix)")
            }
        }

        if !hasContent {
            output.warn("Nothing selected to install.")
            return false
        }

        output.plain("")

        if dryRun {
            output.info("Dry run mode -- no changes will be made.")
            return false
        }

        return output.askYesNo("Proceed with installation?")
    }

    // MARK: - Phase 4: Install

    mutating func phaseInstall(plan: DependencyResolver.ResolvedPlan, state: SelectionState) {
        // Silent base infrastructure install (session_start.sh, settings.json, gitignore)
        installBaseInfrastructure()

        let components = plan.orderedComponents
        let total = components.count

        output.header("Installing...")

        // Initialize manifest
        var manifest = Manifest(path: environment.setupManifest)
        manifest.initialize(sourceDirectory: Bundle.module.bundlePath)

        // Ensure directories exist
        let fm = FileManager.default
        let dirs = [
            environment.claudeDirectory,
            environment.hooksDirectory,
            environment.skillsDirectory,
            environment.commandsDirectory,
        ]
        for dir in dirs {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                output.error("Could not create \(dir.lastPathComponent): \(error.localizedDescription)")
                return
            }
        }

        for (index, component) in components.enumerated() {
            let step = index + 1
            output.step(step, of: total, component.displayName)

            // Check if already installed
            if isAlreadyInstalled(component) {
                skippedItems.append("\(component.displayName) (already installed)")
                output.dimmed("Already installed, skipping")
                manifest.recordInstalledComponent(component.id)
                continue
            }

            let success = installComponent(
                component,
                state: state,
                manifest: &manifest
            )
            if success {
                installedItems.append(component.displayName)
                manifest.recordInstalledComponent(component.id)
                output.success("\(component.displayName) installed")
            } else {
                skippedItems.append("\(component.displayName) (failed)")
                output.warn("Failed to install \(component.displayName)")
            }
        }

        // Record which packs were installed
        let installedPackIDs = Set(
            plan.orderedComponents.compactMap(\.packIdentifier)
        )
        for packID in installedPackIDs {
            manifest.recordInstalledPack(packID)
        }

        // Post-processing: inject pack hook contributions and gitignore entries.
        // These run BEFORE manifest save so that hook file hashes can be
        // re-recorded after injection modifies the installed files.
        var modifiedHookFiles: Set<String> = []
        for packID in installedPackIDs {
            if let pack = registry.pack(for: packID) {
                injectHookContributions(from: pack)
                addPackGitignoreEntries(from: pack)
                for contribution in pack.hookContributions {
                    modifiedHookFiles.insert(contribution.hookName + ".sh")
                }
            }
        }

        // Re-record hashes for hook files modified by post-processing injections.
        // Without this, the manifest would contain the pre-injection source hash,
        // causing doctor freshness checks to report drift on every run.
        for hookFileName in modifiedHookFiles {
            let installedHook = environment.hooksDirectory.appendingPathComponent(hookFileName)
            let relativePath = "hooks/\(hookFileName)"
            if FileManager.default.fileExists(atPath: installedHook.path) {
                do {
                    let hash = try Manifest.sha256(of: installedHook)
                    manifest.recordHash(relativePath: relativePath, hash: hash)
                } catch {
                    output.warn("Could not update manifest hash for \(hookFileName): \(error.localizedDescription)")
                }
            }
        }

        // Save manifest after all post-processing to capture final state
        do {
            try manifest.save()
        } catch {
            output.warn("Could not save manifest: \(error.localizedDescription)")
        }
    }

    // MARK: - Phase 5: Post-Summary

    func phaseSummaryPost(installAll: Bool) {
        output.header("Setup Complete!")

        if !installedItems.isEmpty {
            output.plain("")
            output.plain("  Installed:")
            for item in installedItems {
                output.plain("    + \(item)")
            }
        }

        if !skippedItems.isEmpty {
            output.plain("")
            output.plain("  Skipped:")
            for item in skippedItems {
                output.dimmed("  o \(item)")
            }
        }

        // Offer inline project configuration (interactive installs only)
        if !installAll && !dryRun && !registry.availablePacks.isEmpty {
            output.plain("")
            if output.askYesNo("Configure a project now?") {
                let cwd = FileManager.default.currentDirectoryPath
                let projectPathStr = output.promptInline("Project path", default: cwd)
                let projectPath = URL(fileURLWithPath: projectPathStr)

                guard FileManager.default.fileExists(atPath: projectPath.path) else {
                    output.warn("Directory does not exist: \(projectPath.path)")
                    output.plain("  You can configure later with: cd /path/to/project && mcs configure")
                    return
                }

                let configurator = ProjectConfigurator(
                    environment: environment,
                    output: output,
                    shell: shell,
                    registry: registry
                )
                do {
                    try configurator.interactiveConfigure(at: projectPath)
                } catch {
                    output.warn("Configuration failed: \(error.localizedDescription)")
                    output.plain("  You can retry later with: cd \(projectPath.path) && mcs configure")
                }
            }
        }

        output.plain("")
        output.plain("  Next Steps:")
        output.plain("")
        output.plain("    1. Restart your terminal to pick up PATH changes")
        output.plain("")
        output.plain("    2. Configure more projects:")
        output.plain("       cd /path/to/project && mcs configure")
        output.plain("")
        output.plain("    3. Verify your setup:")
        output.plain("       mcs doctor")
        output.plain("")
    }

    // MARK: - Base Infrastructure

    /// Silently install the base infrastructure that all packs depend on:
    /// session_start.sh, settings.json (deep-merged), and core gitignore entries.
    /// This runs before any pack component installation.
    private mutating func installBaseInfrastructure() {
        let fm = FileManager.default

        // Ensure directories exist
        do {
            try fm.createDirectory(at: environment.hooksDirectory, withIntermediateDirectories: true)
        } catch {
            output.warn("Could not create hooks directory: \(error.localizedDescription)")
        }

        // 1. Copy session_start.sh
        if let sourceURL = resolvedResourceURL("hooks/session_start.sh") {
            let destURL = environment.hooksDirectory.appendingPathComponent(Constants.FileNames.sessionStartHook)
            do {
                try backup.backupFile(at: destURL)
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.copyItem(at: sourceURL, to: destURL)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destURL.path)
            } catch {
                output.warn("Could not install base hook: \(error.localizedDescription)")
            }
        }

        // 2. Deep-merge settings.json
        let settingsMerged = mergeSettings()
        if !settingsMerged {
            output.dimmed("Settings merge skipped or failed")
        }

        // 3. Add core gitignore entries
        let gitignore = GitignoreManager(shell: shell)
        do {
            try gitignore.addCoreEntries()
        } catch {
            output.warn("Could not add gitignore entries: \(error.localizedDescription)")
        }
    }

    // MARK: - Component Installation

    private var executor: ComponentExecutor {
        ComponentExecutor(
            environment: environment,
            output: output,
            shell: shell,
            backup: backup
        )
    }

    private mutating func installComponent(
        _ component: ComponentDefinition,
        state: SelectionState,
        manifest: inout Manifest
    ) -> Bool {
        switch component.installAction {
        case .brewInstall(let package):
            let success = executor.installBrewPackage(package)
            if success {
                executor.postInstall(component)
            }
            return success

        case .shellCommand(let command):
            let result = shell.shell(command)
            if !result.succeeded {
                output.warn(String(result.stderr.prefix(200)))
            }
            return result.succeeded

        case .mcpServer(let config):
            return executor.installMCPServer(config)

        case .plugin(let name):
            return executor.installPlugin(name)

        case .copySkill(let source, let destination):
            return copySkill(source: source, destination: destination, manifest: &manifest)

        case .copyHook(let source, let destination):
            return copyHook(source: source, destination: destination, manifest: &manifest)

        case .copyCommand(let source, let destination, let placeholders):
            return copyCommand(
                source: source,
                destination: destination,
                placeholders: placeholders,
                manifest: &manifest
            )

        case .settingsMerge:
            return mergeSettings()

        case .gitignoreEntries(let entries):
            return executor.addGitignoreEntries(entries)

        case .copyPackFile(let source, let destination, let fileType):
            var exec = executor
            let success = exec.installCopyPackFile(
                source: source,
                destination: destination,
                fileType: fileType,
                manifest: &manifest
            )
            backup = exec.backup
            return success
        }
    }

    /// Resolve a bundled resource path relative to Resources/.
    /// Returns nil (with a warning) if the bundle is missing.
    private func resolvedResourceURL(_ relativePath: String) -> URL? {
        guard let resourceURL = Bundle.module.url(
            forResource: "Resources",
            withExtension: nil
        ) else {
            output.warn("Resources bundle not found")
            return nil
        }
        return resourceURL.appendingPathComponent(relativePath)
    }

    /// Record a manifest entry, warning on failure.
    private func recordManifest(
        _ manifest: inout Manifest,
        relativePath: String,
        sourceFile: URL
    ) {
        do {
            try manifest.record(relativePath: relativePath, sourceFile: sourceFile)
        } catch {
            output.warn("Could not record manifest entry for \(relativePath): \(error.localizedDescription)")
        }
    }

    private mutating func copySkill(
        source: String,
        destination: String,
        manifest: inout Manifest
    ) -> Bool {
        let fm = FileManager.default
        guard let sourceURL = resolvedResourceURL(source) else { return false }
        let destURL = environment.skillsDirectory.appendingPathComponent(destination)

        do {
            try fm.createDirectory(at: destURL, withIntermediateDirectories: true)

            guard fm.fileExists(atPath: sourceURL.path) else {
                output.warn("Source not found: \(source)")
                return false
            }

            let contents = try fm.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: nil
            )
            for file in contents {
                let destFile = destURL.appendingPathComponent(file.lastPathComponent)
                do {
                    try backup.backupFile(at: destFile)
                } catch {
                    output.warn("Could not backup \(destFile.lastPathComponent): \(error.localizedDescription)")
                }
                if fm.fileExists(atPath: destFile.path) {
                    try fm.removeItem(at: destFile)
                }
                // copyItem handles directories recursively
                try fm.copyItem(at: file, to: destFile)
            }

            // Record per-file hashes instead of per-directory
            // (directories can't be hashed by Data(contentsOf:))
            do {
                let fileHashes = try Manifest.directoryFileHashes(at: sourceURL)
                for entry in fileHashes {
                    manifest.recordHash(
                        relativePath: "\(source)/\(entry.relativePath)",
                        hash: entry.hash
                    )
                }
            } catch {
                output.warn("Could not record manifest hashes for \(source): \(error.localizedDescription)")
            }
            return true
        } catch {
            output.warn(error.localizedDescription)
            return false
        }
    }

    private mutating func copyHook(
        source: String,
        destination: String,
        manifest: inout Manifest
    ) -> Bool {
        let fm = FileManager.default
        guard let sourceURL = resolvedResourceURL(source) else { return false }
        let destURL = environment.hooksDirectory.appendingPathComponent(destination)

        do {
            try fm.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try backup.backupFile(at: destURL)
            } catch {
                output.warn("Could not backup \(destURL.lastPathComponent): \(error.localizedDescription)")
            }
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: sourceURL, to: destURL)

            // Make executable
            try fm.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destURL.path
            )

            recordManifest(&manifest, relativePath: source, sourceFile: destURL)
            return true
        } catch {
            output.warn(error.localizedDescription)
            return false
        }
    }

    private mutating func copyCommand(
        source: String,
        destination: String,
        placeholders: [String: String],
        manifest: inout Manifest
    ) -> Bool {
        let fm = FileManager.default
        guard let sourceURL = resolvedResourceURL(source) else { return false }
        let destURL = environment.commandsDirectory.appendingPathComponent(destination)

        do {
            try fm.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var content = try String(contentsOf: sourceURL, encoding: .utf8)
            content = TemplateEngine.substitute(template: content, values: placeholders)

            do {
                try backup.backupFile(at: destURL)
            } catch {
                output.warn("Could not backup \(destURL.lastPathComponent): \(error.localizedDescription)")
            }
            try content.write(to: destURL, atomically: true, encoding: .utf8)
            recordManifest(&manifest, relativePath: source, sourceFile: destURL)
            return true
        } catch {
            output.warn(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    private mutating func mergeSettings() -> Bool {
        guard let sourceURL = resolvedResourceURL("config/settings.json") else { return false }
        let destURL = environment.claudeSettings

        do {
            let template = try Settings.load(from: sourceURL)
            var existing = try Settings.load(from: destURL)

            do {
                try backup.backupFile(at: destURL)
            } catch {
                output.warn("Could not backup settings: \(error.localizedDescription)")
            }

            // Bootstrap ownership from legacy bash manifest if no sidecar exists yet
            var ownership = SettingsOwnership(path: environment.settingsKeys)
            if ownership.managedKeys.isEmpty {
                if ownership.bootstrapFromLegacyManifest(at: environment.setupManifest) {
                    output.dimmed("Migrated ownership from legacy bash installer manifest")
                }
            }

            // Remove stale keys that mcs previously owned but are no longer in the template
            let stale = ownership.staleKeys(comparedTo: template)
            if !stale.isEmpty {
                existing.removeKeys(stale)
                for key in stale {
                    ownership.remove(keyPath: key)
                }
                output.dimmed("Removed \(stale.count) stale setting(s): \(stale.joined(separator: ", "))")
            }

            existing.merge(with: template)
            try existing.save(to: destURL)

            // Record ownership of all template keys
            ownership.recordAll(from: template, version: MCSVersion.current)
            do {
                try ownership.save()
            } catch {
                output.warn("Could not save settings ownership: \(error.localizedDescription)")
            }

            return true
        } catch {
            // Merge failed — report the error instead of silently overwriting user settings
            output.warn("Settings merge failed: \(error.localizedDescription)")
            output.warn("Your existing settings at \(destURL.path) were preserved.")
            output.warn("Run 'mcs install' again or manually merge settings.")
            return false
        }
    }

    // MARK: - Pack Post-Processing

    private mutating func injectHookContributions(from pack: any TechPack) {
        var exec = executor
        exec.injectHookContributions(from: pack)
        backup = exec.backup
    }

    private func addPackGitignoreEntries(from pack: any TechPack) {
        executor.addPackGitignoreEntries(from: pack)
    }

    private func isAlreadyInstalled(_ component: ComponentDefinition) -> Bool {
        ComponentExecutor.isAlreadyInstalled(component)
    }
}
