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
        let xcodeResult = shell.run("/usr/bin/xcode-select", arguments: ["-p"], quiet: true)
        if xcodeResult.succeeded {
            output.info("Xcode Command Line Tools: installed")
        } else {
            output.warn("Xcode Command Line Tools not found.")
            output.plain("  Install them with: xcode-select --install")
            output.plain("  Then re-run this tool.")
            throw MCSError.dependencyMissing("Xcode Command Line Tools")
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
            state.selectAll(from: allComponents)
            // Also select all pack components
            for pack in allPacks {
                for component in pack.components where component.type != .brewPackage {
                    state.select(component.id)
                }
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

        // Interactive selection
        output.plain("")
        if output.askYesNo("Install everything? (skip individual prompts)", default: false) {
            state.selectAll(from: allComponents)
            for pack in allPacks {
                for component in pack.components where component.type != .brewPackage {
                    state.select(component.id)
                }
            }
            askBranchPrefix(&state)
            return state
        }

        // Select required core components
        state.selectRequiredCore(from: coreComponents)

        // Interactive category selection
        interactiveSelectByCategory(&state, coreComponents: coreComponents)

        // Available tech packs
        if !allPacks.isEmpty {
            output.header("Tech Packs")
            output.dimmed("Tech packs add components specialized for a platform or workflow.")
            output.plain("")
            for pack in allPacks {
                output.plain("  \(pack.displayName)")
                output.dimmed(pack.description)
                if output.askYesNo("Install \(pack.displayName) pack?") {
                    for component in pack.components where component.type != .brewPackage {
                        state.select(component.id)
                    }
                }
                output.plain("")
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
            output.plain("  \(type.rawValue)s:")
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
        manifest.initialize(sourceDirectory: Bundle.main.bundlePath)

        // Ensure directories exist
        let fm = FileManager.default
        let dirs = [
            environment.claudeDirectory,
            environment.hooksDirectory,
            environment.skillsDirectory,
            environment.commandsDirectory,
        ]
        for dir in dirs {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
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

        // Save manifest
        try? manifest.save()
    }

    // MARK: - Phase 5: Post-Summary

    func phaseSummaryPost() {
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

        output.plain("")
        output.plain("  Next Steps:")
        output.plain("")
        output.plain("    1. Restart your terminal to pick up PATH changes")
        output.plain("")
        output.plain("    2. Configure CLAUDE.local.md for your project(s)")
        output.dimmed("     Run: mcs configure <project-path>")
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
            return installBrewPackage(package)

        case .shellCommand(let command):
            return shell.shell(command).succeeded

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
            output.dimmed(String(result.stderr.prefix(200)))
        }
        return result.succeeded
    }

    private func installMCPServer(_ config: MCPServerConfig) -> Bool {
        guard shell.commandExists("claude") else {
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
        guard shell.commandExists("claude") else {
            output.warn("Claude Code CLI not found, skipping plugin")
            return false
        }
        let claude = ClaudeIntegration(shell: shell)
        let result = claude.pluginInstall(fullName: fullName)
        return result.succeeded
    }

    private mutating func copySkill(
        source: String,
        destination: String,
        manifest: inout Manifest
    ) -> Bool {
        let fm = FileManager.default
        guard let resourceURL = Bundle.main.url(
            forResource: "Resources",
            withExtension: nil
        ) else {
            output.warn("Resources bundle not found")
            return false
        }

        let sourceURL = resourceURL.appendingPathComponent(source)
        let destURL = environment.skillsDirectory.appendingPathComponent(destination)

        do {
            try? fm.createDirectory(
                at: destURL,
                withIntermediateDirectories: true
            )
            // Copy all files in the skill directory
            if fm.fileExists(atPath: sourceURL.path) {
                let contents = try fm.contentsOfDirectory(
                    at: sourceURL,
                    includingPropertiesForKeys: nil
                )
                for file in contents {
                    let destFile = destURL.appendingPathComponent(file.lastPathComponent)
                    _ = try? backup.backupFile(at: destFile)
                    if fm.fileExists(atPath: destFile.path) {
                        try fm.removeItem(at: destFile)
                    }
                    try fm.copyItem(at: file, to: destFile)

                    // Recurse into subdirectories
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue {
                        let subContents = try fm.contentsOfDirectory(
                            at: file,
                            includingPropertiesForKeys: nil
                        )
                        for subFile in subContents {
                            let subDest = destFile.appendingPathComponent(subFile.lastPathComponent)
                            if fm.fileExists(atPath: subDest.path) {
                                try fm.removeItem(at: subDest)
                            }
                            try fm.copyItem(at: subFile, to: subDest)
                        }
                    }
                }
                try? manifest.record(
                    relativePath: source,
                    sourceFile: sourceURL
                )
            }
            return true
        } catch {
            output.dimmed(error.localizedDescription)
            return false
        }
    }

    private mutating func copyHook(
        source: String,
        destination: String,
        manifest: inout Manifest
    ) -> Bool {
        let fm = FileManager.default
        guard let resourceURL = Bundle.main.url(
            forResource: "Resources",
            withExtension: nil
        ) else {
            output.warn("Resources bundle not found")
            return false
        }

        let sourceURL = resourceURL.appendingPathComponent(source)
        let destURL = environment.hooksDirectory.appendingPathComponent(destination)

        do {
            try? fm.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try? backup.backupFile(at: destURL)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: sourceURL, to: destURL)

            // Make executable
            try fm.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destURL.path
            )

            try? manifest.record(relativePath: source, sourceFile: sourceURL)
            return true
        } catch {
            output.dimmed(error.localizedDescription)
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
        guard let resourceURL = Bundle.main.url(
            forResource: "Resources",
            withExtension: nil
        ) else {
            output.warn("Resources bundle not found")
            return false
        }

        let sourceURL = resourceURL.appendingPathComponent(source)
        let destURL = environment.commandsDirectory.appendingPathComponent(destination)

        do {
            try? fm.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var content = try String(contentsOf: sourceURL, encoding: .utf8)
            content = TemplateEngine.substitute(template: content, values: placeholders)

            _ = try? backup.backupFile(at: destURL)
            try content.write(to: destURL, atomically: true, encoding: .utf8)
            try? manifest.record(relativePath: source, sourceFile: sourceURL)
            return true
        } catch {
            output.dimmed(error.localizedDescription)
            return false
        }
    }

    private mutating func mergeSettings() -> Bool {
        guard let resourceURL = Bundle.main.url(
            forResource: "Resources",
            withExtension: nil
        ) else {
            output.warn("Resources bundle not found")
            return false
        }

        let sourceURL = resourceURL
            .appendingPathComponent("config")
            .appendingPathComponent("settings.json")
        let destURL = environment.claudeSettings

        do {
            let template = try Settings.load(from: sourceURL)
            var existing = try Settings.load(from: destURL)

            _ = try? backup.backupFile(at: destURL)

            existing.merge(with: template)
            try existing.save(to: destURL)
            return true
        } catch {
            // Fallback: just copy the template settings
            let fm = FileManager.default
            do {
                try? fm.createDirectory(
                    at: destURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fm.fileExists(atPath: sourceURL.path) {
                    _ = try? backup.backupFile(at: destURL)
                    try fm.copyItem(at: sourceURL, to: destURL)
                }
                return true
            } catch {
                output.dimmed(error.localizedDescription)
                return false
            }
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

    // MARK: - Already-installed detection

    private func isAlreadyInstalled(_ component: ComponentDefinition) -> Bool {
        switch component.installAction {
        case .brewInstall(let package):
            return shell.commandExists(package)

        case .mcpServer(let config):
            // Check if it exists in ~/.claude.json
            let fm = FileManager.default
            guard fm.fileExists(atPath: environment.claudeJSON.path) else { return false }
            guard let data = try? Data(contentsOf: environment.claudeJSON),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = json["mcpServers"] as? [String: Any]
            else { return false }
            return servers[config.name] != nil

        case .plugin:
            return false // No reliable way to check

        case .copySkill(_, let destination):
            let dest = environment.skillsDirectory.appendingPathComponent(destination)
            return FileManager.default.fileExists(atPath: dest.path)

        case .copyHook(_, let destination):
            let dest = environment.hooksDirectory.appendingPathComponent(destination)
            return FileManager.default.fileExists(atPath: dest.path)

        case .copyCommand(_, let destination, _):
            let dest = environment.commandsDirectory.appendingPathComponent(destination)
            return FileManager.default.fileExists(atPath: dest.path)

        case .settingsMerge:
            return false // Always run merge to pick up new settings

        case .gitignoreEntries:
            return false // Idempotent, safe to re-run

        case .shellCommand:
            return false
        }
    }

    // MARK: - Interactive Selection Helpers

    private func interactiveSelectByCategory(
        _ state: inout SelectionState,
        coreComponents: [ComponentDefinition]
    ) {
        let grouped = CoreComponents.grouped

        for (type, components) in grouped {
            output.header(type.rawValue + "s")
            output.dimmed(descriptionForType(type))
            output.plain("")

            for (index, component) in components.enumerated() {
                output.plain("  \(index + 1). \(component.displayName)")
                output.dimmed("   \(component.description)")
                if !component.isRequired {
                    if output.askYesNo("Install \(component.displayName)?") {
                        state.select(component.id)
                    }
                } else {
                    state.select(component.id)
                    output.dimmed("   (required, will be installed)")
                }
                output.plain("")
            }
        }
    }

    private func descriptionForType(_ type: ComponentType) -> String {
        switch type {
        case .mcpServer:
            return "MCP servers give Claude specialized capabilities."
        case .plugin:
            return "Plugins extend Claude Code with specialized features."
        case .skill:
            return "Skills provide specialized knowledge and workflows."
        case .command:
            return "Custom slash commands for Claude Code."
        case .hookFile:
            return "Hooks run automatically at key points in the session."
        case .configuration:
            return "Settings and configuration for Claude Code."
        case .brewPackage:
            return "System dependencies."
        }
    }

    private func askBranchPrefix(_ state: inout SelectionState) {
        if state.isSelected("core.command.pr") {
            output.plain("")
            output.plain("  Your name for branch naming (e.g. bruno -> bruno/ABC-123-fix-login)")
            output.plain("  Leave empty for feature/ABC-123-fix-login")
            output.plain("")
            if let answer = readLine()?.trimmingCharacters(in: .whitespaces), !answer.isEmpty {
                state.branchPrefix = answer
            } else {
                state.branchPrefix = "feature"
                output.info("Defaulting branch prefix to: feature")
            }
        }
    }
}
