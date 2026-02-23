import Foundation

/// Installs pack components with dependency resolution.
/// Used by `ConfigureCommand` (mcs configure) to auto-install missing pack dependencies.
/// Delegates to `ComponentExecutor` for shared install logic, ensuring consistent
/// behavior with `Installer` (mcs install).
struct PackInstaller {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner
    var backup: Backup
    let registry: TechPackRegistry

    init(
        environment: Environment,
        output: CLIOutput,
        shell: ShellRunner,
        backup: Backup = Backup(),
        registry: TechPackRegistry = .shared
    ) {
        self.environment = environment
        self.output = output
        self.shell = shell
        self.backup = backup
        self.registry = registry
    }

    private var executor: ComponentExecutor {
        ComponentExecutor(
            environment: environment,
            output: output,
            shell: shell,
            backup: backup
        )
    }

    /// Install missing components for a pack. Returns true if all succeeded.
    @discardableResult
    mutating func installPack(_ pack: any TechPack) -> Bool {
        let allComponents = registry.allPackComponents

        // Select all pack components
        let selectedIDs = Set(pack.components.map(\.id))

        // Resolve dependencies
        let plan: DependencyResolver.ResolvedPlan
        do {
            plan = try DependencyResolver.resolve(
                selectedIDs: selectedIDs,
                allComponents: allComponents
            )
        } catch {
            output.error("Failed to resolve pack dependencies: \(error.localizedDescription)")
            return false
        }

        // Filter to components that aren't already installed
        let missing = plan.orderedComponents.filter {
            !ComponentExecutor.isAlreadyInstalled($0)
        }

        if missing.isEmpty {
            output.dimmed("All \(pack.displayName) components already installed")
            return true
        }

        output.plain("")
        output.plain("  Installing \(pack.displayName) pack components...")
        let total = missing.count
        var allSucceeded = true

        for (index, component) in missing.enumerated() {
            output.step(index + 1, of: total, component.displayName)

            let success = installComponent(component)
            if success {
                output.success("\(component.displayName) installed")
            } else {
                output.warn("Failed to install \(component.displayName)")
                allSucceeded = false
            }
        }

        // Post-processing: gitignore entries
        let exec = executor
        exec.addPackGitignoreEntries(from: pack)

        return allSucceeded
    }

    // MARK: - Component Installation

    private mutating func installComponent(_ component: ComponentDefinition) -> Bool {
        var exec = executor

        switch component.installAction {
        case .brewInstall(let package):
            return exec.installBrewPackage(package)

        case .shellCommand(let command):
            let result = shell.shell(command)
            if !result.succeeded {
                output.warn(String(result.stderr.prefix(200)))
            }
            return result.succeeded

        case .mcpServer(let config):
            return exec.installMCPServer(config)

        case .plugin(let name):
            return exec.installPlugin(name)

        case .gitignoreEntries(let entries):
            return exec.addGitignoreEntries(entries)

        case .copyPackFile(let source, let destination, let fileType):
            let success = exec.installCopyPackFile(
                source: source,
                destination: destination,
                fileType: fileType
            )
            backup = exec.backup
            return success

        case .settingsMerge:
            // Settings merge is handled at the project level by ProjectConfigurator.
            return true
        }
    }
}
