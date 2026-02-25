import Foundation

/// Orchestrates the 5-phase install flow:
/// welcome -> selection -> summary -> install -> post-summary.
///
/// Note: `mcs install` is deprecated in favor of `mcs sync`.
/// This installer handles global-scope component installation
/// for packs that declare brew packages, MCP servers, plugins, etc.
struct Installer {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner
    let dryRun: Bool
    let registry: TechPackRegistry

    private var installedItems: [String] = []
    private var skippedItems: [String] = []

    init(
        environment: Environment,
        output: CLIOutput,
        shell: ShellRunner,
        dryRun: Bool,
        registry: TechPackRegistry = .shared
    ) {
        self.environment = environment
        self.output = output
        self.shell = shell
        self.dryRun = dryRun
        self.registry = registry
    }

    // MARK: - Phase 1: Welcome

    mutating func phaseWelcome() throws {
        output.header("Managed Claude Stack")
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
            output.plain("  Then re-run: mcs sync")
            throw MCSError.dependencyMissing("Homebrew")
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

        if installAll {
            for pack in allPacks {
                state.selectPack(
                    pack.identifier,
                    packComponents: pack.components
                )
            }
            return state
        }

        if let packName {
            if let pack = registry.pack(for: packName) {
                state.selectPack(
                    packName,
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
        // Add core gitignore entries
        let gitignore = GitignoreManager(shell: shell)
        do {
            try gitignore.addCoreEntries()
        } catch {
            output.warn("Could not add gitignore entries: \(error.localizedDescription)")
        }

        let components = plan.orderedComponents
        let total = components.count

        output.header("Installing...")

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
                state: state
            )
            if success {
                installedItems.append(component.displayName)
                output.success("\(component.displayName) installed")
            } else {
                skippedItems.append("\(component.displayName) (failed)")
                output.warn("Failed to install \(component.displayName)")
            }
        }

        // Post-processing: add pack gitignore entries
        let installedPackIDs = Set(
            plan.orderedComponents.compactMap(\.packIdentifier)
        )
        for packID in installedPackIDs {
            if let pack = registry.pack(for: packID) {
                addPackGitignoreEntries(from: pack)
            }
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
                    output.plain("  You can configure later with: cd /path/to/project && mcs sync")
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
                    output.plain("  You can retry later with: cd \(projectPath.path) && mcs sync")
                }
            }
        }

        output.plain("")
        output.plain("  Next Steps:")
        output.plain("")
        output.plain("    1. Restart your terminal to pick up PATH changes")
        output.plain("")
        output.plain("    2. Configure more projects:")
        output.plain("       cd /path/to/project && mcs sync")
        output.plain("")
        output.plain("    3. Verify your setup:")
        output.plain("       mcs doctor")
        output.plain("")
    }

    // MARK: - Component Installation

    private var executor: ComponentExecutor {
        ComponentExecutor(
            environment: environment,
            output: output,
            shell: shell
        )
    }

    private func installComponent(
        _ component: ComponentDefinition,
        state: SelectionState
    ) -> Bool {
        switch component.installAction {
        case .brewInstall(let package):
            return executor.installBrewPackage(package)

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

        case .gitignoreEntries(let entries):
            return executor.addGitignoreEntries(entries)

        case .copyPackFile(let source, let destination, let fileType):
            return executor.installCopyPackFile(
                source: source,
                destination: destination,
                fileType: fileType
            )

        case .settingsMerge:
            // Settings merge is handled at the project level by ProjectConfigurator.
            output.dimmed("Skipped settingsMerge for \(component.displayName)")
            return true
        }
    }

    private func addPackGitignoreEntries(from pack: any TechPack) {
        executor.addPackGitignoreEntries(from: pack)
    }

    private func isAlreadyInstalled(_ component: ComponentDefinition) -> Bool {
        ComponentExecutor.isAlreadyInstalled(component)
    }
}
