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

    init(
        environment: Environment,
        output: CLIOutput,
        shell: ShellRunner,
        backup: Backup = Backup()
    ) {
        self.environment = environment
        self.output = output
        self.shell = shell
        self.backup = backup
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
        let coreComponents = CoreComponents.all
        let allComponents = TechPackRegistry.shared.allComponents(includingCore: coreComponents)

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

        // Post-processing: hook contributions and gitignore
        var exec = executor
        exec.injectHookContributions(from: pack)
        exec.addPackGitignoreEntries(from: pack)
        backup = exec.backup

        // Record pack in manifest and re-record hashes for hook files
        // modified by injection (must happen after injection, not before)
        var manifest = Manifest(path: environment.setupManifest)
        manifest.recordInstalledPack(pack.identifier)

        for contribution in pack.hookContributions {
            let hookFileName = contribution.hookName + ".sh"
            let installedHook = environment.hooksDirectory.appendingPathComponent(hookFileName)
            let relativePath = "hooks/\(hookFileName)"
            guard FileManager.default.fileExists(atPath: installedHook.path) else {
                output.warn("Expected hook file \(hookFileName) not found — hash not recorded")
                continue
            }
            do {
                let hash = try Manifest.sha256(of: installedHook)
                manifest.recordHash(relativePath: relativePath, hash: hash)
            } catch {
                output.warn("Could not update manifest hash for \(hookFileName): \(error.localizedDescription)")
            }
        }

        do {
            try manifest.save()
        } catch {
            output.warn("Could not save manifest: \(error.localizedDescription)")
        }

        return allSucceeded
    }

    // MARK: - Component Installation

    private func installComponent(_ component: ComponentDefinition) -> Bool {
        let exec = executor

        switch component.installAction {
        case .brewInstall(let package):
            let success = exec.installBrewPackage(package)
            if success {
                exec.postInstall(component)
            }
            return success

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

        case .copySkill, .copyHook, .copyCommand, .settingsMerge:
            // These are core-only actions, not used by pack components
            return true
        }
    }
}
