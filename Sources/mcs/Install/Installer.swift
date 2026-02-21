import Foundation

/// Orchestrates the 5-phase install flow:
/// welcome -> selection -> summary -> install -> post-summary.
struct Installer {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner
    var backup: Backup
    let dryRun: Bool

    private var installedItems: [String] = []
    private var skippedItems: [String] = []

    init(
        environment: Environment,
        output: CLIOutput,
        shell: ShellRunner,
        backup: Backup = Backup(),
        dryRun: Bool
    ) {
        self.environment = environment
        self.output = output
        self.shell = shell
        self.backup = backup
        self.dryRun = dryRun
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

        let coreComponents = CoreComponents.all
        let registry = TechPackRegistry.shared
        let allPacks = registry.availablePacks
        let allComponents = registry.allComponents(includingCore: coreComponents)

        if installAll {
            state.selectAllCore(from: allComponents)
            // --all explicitly includes all packs
            for pack in allPacks {
                state.selectPack(
                    pack.identifier,
                    coreComponents: coreComponents,
                    packComponents: pack.components
                )
            }
            askBranchPrefix(&state)
            return state
        }

        if let packName {
            if let pack = registry.pack(for: packName) {
                state.selectPack(
                    packName,
                    coreComponents: coreComponents,
                    packComponents: pack.components
                )
                output.info("Selected tech pack: \(pack.displayName)")
            } else {
                output.warn("Unknown tech pack: \(packName)")
                output.plain("  Available packs: \(allPacks.map(\.identifier).joined(separator: ", "))")
            }
            askBranchPrefix(&state)
            return state
        }

        // Interactive multi-select
        output.header("Component Selection")

        let selection = CoreComponents.groupedForSelection
        var numberToComponentIDs: [Int: [String]] = [:]
        var number = 1

        // Build selectable groups: bundles first, then individual components
        var groups: [SelectableGroup] = []

        // Feature bundles
        let bundles = CoreComponents.bundles
        if !bundles.isEmpty {
            var bundleItems: [SelectableItem] = []
            for bundle in bundles {
                bundleItems.append(SelectableItem(
                    number: number,
                    name: bundle.name,
                    description: bundle.description,
                    isSelected: true
                ))
                numberToComponentIDs[number] = bundle.componentIDs
                number += 1
            }
            groups.append(SelectableGroup(
                title: "Features",
                items: bundleItems,
                requiredItems: []
            ))
        }

        // Individual components (excludes bundled ones)
        for (type, components) in selection.selectable {
            var items: [SelectableItem] = []
            for component in components {
                items.append(SelectableItem(
                    number: number,
                    name: component.displayName,
                    description: component.description,
                    isSelected: true
                ))
                numberToComponentIDs[number] = [component.id]
                number += 1
            }
            groups.append(SelectableGroup(
                title: type.rawValue,
                items: items,
                requiredItems: []
            ))
        }

        // Add required items to a dedicated group
        let requiredItems = selection.required.map { RequiredItem(name: $0.displayName) }
        if !requiredItems.isEmpty {
            groups.append(SelectableGroup(
                title: "",
                items: [],
                requiredItems: requiredItems
            ))
        }

        let selectedNumbers = output.multiSelect(groups: &groups)

        // Translate selections back to component IDs
        state.selectRequiredCore(from: coreComponents)
        for (num, componentIDs) in numberToComponentIDs {
            if selectedNumbers.contains(num) {
                for id in componentIDs {
                    state.select(id)
                }
            }
        }

        askBranchPrefix(&state)
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
                continue
            }

            let success = installComponent(
                component,
                state: state,
                manifest: &manifest
            )
            if success {
                installedItems.append(component.displayName)
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

        // Save manifest
        do {
            try manifest.save()
        } catch {
            output.warn("Could not save manifest: \(error.localizedDescription)")
        }

        // Post-processing: inject pack hook contributions and gitignore entries
        for packID in installedPackIDs {
            if let pack = TechPackRegistry.shared.pack(for: packID) {
                injectHookContributions(from: pack)
                addPackGitignoreEntries(from: pack)
            }
        }

        // Post-processing: continuous learning hook fragment + settings entry
        if state.isSelected("core.docs-mcp-server") {
            injectContinuousLearningHook()
            registerContinuousLearningSettings()
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
        if !installAll && !dryRun && !TechPackRegistry.shared.availablePacks.isEmpty {
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
                    shell: shell
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


    // MARK: - Component Installation

    private mutating func installComponent(
        _ component: ComponentDefinition,
        state: SelectionState,
        manifest: inout Manifest
    ) -> Bool {
        switch component.installAction {
        case .brewInstall(let package):
            let success = installBrewPackage(package)
            if success {
                postInstall(component)
            }
            return success

        case .shellCommand(let command):
            let result = shell.shell(command)
            if !result.succeeded {
                output.warn(String(result.stderr.prefix(200)))
            }
            return result.succeeded

        case .mcpServer(let config):
            return installMCPServer(config)

        case .plugin(let name):
            return installPlugin(name)

        case .copySkill(let source, let destination):
            return copySkill(source: source, destination: destination, manifest: &manifest)

        case .copyHook(let source, let destination):
            return copyHook(source: source, destination: destination, manifest: &manifest)

        case .copyCommand(let source, let destination, var placeholders):
            placeholders["BRANCH_PREFIX"] = state.branchPrefix
            return copyCommand(
                source: source,
                destination: destination,
                placeholders: placeholders,
                manifest: &manifest
            )

        case .settingsMerge:
            return mergeSettings()

        case .gitignoreEntries(let entries):
            return addGitignoreEntries(entries)
        }
    }

    private func installBrewPackage(_ package: String) -> Bool {
        // Already available (installed via any method — Homebrew, macOS app, nvm, etc.)
        if shell.commandExists(package) {
            return true
        }
        let brew = Homebrew(shell: shell, environment: environment)
        guard brew.isInstalled else {
            output.warn("Homebrew not found, cannot install \(package)")
            return false
        }
        if brew.isPackageInstalled(package) {
            return true
        }
        let result = brew.install(package)
        if !result.succeeded {
            output.warn(String(result.stderr.prefix(200)))
        }
        return result.succeeded
    }

    private func installMCPServer(_ config: MCPServerConfig) -> Bool {
        guard shell.commandExists(Constants.CLI.claudeCommand) else {
            output.warn("Claude Code CLI not found, skipping MCP server")
            return false
        }
        let claude = ClaudeIntegration(shell: shell)

        // Build arguments
        var args: [String] = []
        for (key, value) in config.env.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["-e", "\(key)=\(value)"])
        }
        if config.command == "http" {
            args.append(contentsOf: ["--transport", "http"])
            args.append(contentsOf: config.args)
        } else {
            args.append("--")
            args.append(config.command)
            args.append(contentsOf: config.args)
        }

        let result = claude.mcpAdd(name: config.name, arguments: args)
        return result.succeeded
    }

    private func installPlugin(_ fullName: String) -> Bool {
        guard shell.commandExists(Constants.CLI.claudeCommand) else {
            output.warn("Claude Code CLI not found, skipping plugin")
            return false
        }
        let claude = ClaudeIntegration(shell: shell)
        let result = claude.pluginInstall(fullName: fullName)
        return result.succeeded
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

            recordManifest(&manifest, relativePath: source, sourceFile: sourceURL)
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
            recordManifest(&manifest, relativePath: source, sourceFile: sourceURL)
            return true
        } catch {
            output.warn(error.localizedDescription)
            return false
        }
    }

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

    /// Run post-install steps for specific components (e.g., start services, pull models).
    private func postInstall(_ component: ComponentDefinition) {
        switch component.id {
        case "core.ollama":
            let ollama = OllamaService(shell: shell, environment: environment)
            if ollama.isRunning() {
                output.dimmed("Ollama already running")
            } else {
                output.dimmed("Starting Ollama...")
                if !ollama.start() {
                    output.warn("Could not start Ollama automatically.")
                    output.warn("Start it manually with 'ollama serve' or open the Ollama app, then re-run.")
                }
            }
            output.dimmed("Pulling \(Constants.Ollama.embeddingModel) model...")
            if let result = ollama.pullEmbeddingModelIfNeeded(), !result.succeeded {
                output.warn("Could not pull \(Constants.Ollama.embeddingModel): \(result.stderr)")
            }
        default:
            break
        }
    }

    private func addGitignoreEntries(_ entries: [String]) -> Bool {
        let manager = GitignoreManager(shell: shell)
        do {
            for entry in entries {
                try manager.addEntry(entry)
            }
            return true
        } catch {
            output.dimmed(error.localizedDescription)
            return false
        }
    }

    // MARK: - Pack Post-Processing

    /// Inject a pack's hook contributions into installed hook files using section markers.
    private mutating func injectHookContributions(from pack: any TechPack) {
        for contribution in pack.hookContributions {
            let hookFile = environment.hooksDirectory
                .appendingPathComponent(contribution.hookName + ".sh")
            HookInjector.inject(
                fragment: contribution.scriptFragment,
                identifier: pack.identifier,
                into: hookFile,
                backup: &backup,
                output: output
            )
        }
    }

    /// Add a pack's gitignore entries to the global gitignore.
    private func addPackGitignoreEntries(from pack: any TechPack) {
        guard !pack.gitignoreEntries.isEmpty else { return }
        let manager = GitignoreManager(shell: shell)
        for entry in pack.gitignoreEntries {
            do {
                try manager.addEntry(entry)
            } catch {
                output.warn("Failed to add gitignore entry '\(entry)': \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Already-installed detection

    /// Check if a component is already installed.
    /// Delegates to the same derived + supplementary doctor checks used by `mcs doctor`,
    /// ensuring install and doctor always use the same detection logic.
    /// Returns true if ANY check (derived OR supplementary) passes — this means
    /// a component with a passing supplementary check is considered installed even
    /// if its derived check fails.
    private func isAlreadyInstalled(_ component: ComponentDefinition) -> Bool {
        // Idempotent actions: always re-run
        switch component.installAction {
        case .settingsMerge, .gitignoreEntries:
            return false
        default:
            break
        }

        // Try derived check (auto-generated from installAction)
        if let check = component.deriveDoctorCheck() {
            if case .pass = check.check() { return true }
        }

        // Try supplementary checks (component-specific extras)
        for check in component.supplementaryChecks {
            if case .pass = check.check() { return true }
        }

        return false
    }

    // MARK: - Continuous Learning Post-Processing

    /// Inject the Ollama/docs-mcp memory sync fragment into session_start.sh
    /// using section markers for idempotent updates.
    private mutating func injectContinuousLearningHook() {
        let hookFile = environment.hooksDirectory.appendingPathComponent(Constants.FileNames.sessionStartHook)
        HookInjector.inject(
            fragment: CoreComponents.continuousLearningHookFragment,
            identifier: Constants.Hooks.continuousLearningFragmentID,
            into: hookFile,
            backup: &backup,
            output: output
        )
    }

    /// Register the UserPromptSubmit hook for the continuous learning activator in settings.json.
    private func registerContinuousLearningSettings() {
        let settingsPath = environment.claudeSettings
        let activatorCommand = "bash ~/.claude/hooks/\(Constants.FileNames.continuousLearningHook)"

        do {
            var settings = try Settings.load(from: settingsPath)

            if settings.hooks == nil {
                settings.hooks = [:]
            }

            // Check if already registered
            let existing = settings.hooks?[Constants.Hooks.eventUserPromptSubmit] ?? []
            let alreadyRegistered = existing.contains { group in
                group.hooks?.contains { $0.command == activatorCommand } ?? false
            }

            if !alreadyRegistered {
                let hookGroup = Settings.HookGroup(
                    matcher: "",
                    hooks: [Settings.HookEntry(type: "command", command: activatorCommand)]
                )
                settings.hooks?[Constants.Hooks.eventUserPromptSubmit, default: []].append(hookGroup)
                try settings.save(to: settingsPath)
                output.dimmed("Registered continuous learning hook in settings")
            }
        } catch {
            output.warn("Could not register continuous learning hook: \(error.localizedDescription)")
        }
    }

    // MARK: - Interactive Selection Helpers

    private func askBranchPrefix(_ state: inout SelectionState) {
        if state.isSelected("core.command.pr") {
            output.plain("")
            output.plain("  Your name for branch naming (e.g. bruno \u{2192} bruno/ABC-123-fix-login)")
            state.branchPrefix = output.promptInline("Branch prefix", default: "feature")
        }
    }
}
