import Foundation

/// Installs pack components with dependency resolution.
/// Shared between `Installer` (mcs install) and `ConfigureCommand` (mcs configure).
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
        let missing = plan.orderedComponents.filter { !isAlreadyInstalled($0) }

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

        // Record pack in manifest
        var manifest = Manifest(path: environment.setupManifest)
        manifest.recordInstalledPack(pack.identifier)
        do {
            try manifest.save()
        } catch {
            output.warn("Could not save manifest: \(error.localizedDescription)")
        }

        // Post-processing: hook contributions and gitignore
        injectHookContributions(from: pack)
        addPackGitignoreEntries(from: pack)

        return allSucceeded
    }

    // MARK: - Component Installation

    private func installComponent(_ component: ComponentDefinition) -> Bool {
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

        case .gitignoreEntries(let entries):
            return addGitignoreEntries(entries)

        case .copySkill, .copyHook, .copyCommand, .settingsMerge:
            // These are core-only actions, not used by pack components
            return true
        }
    }

    private func installBrewPackage(_ package: String) -> Bool {
        if shell.commandExists(package) { return true }
        let brew = Homebrew(shell: shell, environment: environment)
        guard brew.isInstalled else {
            output.warn("Homebrew not found, cannot install \(package)")
            return false
        }
        if brew.isPackageInstalled(package) { return true }
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

    // MARK: - Already-installed detection

    func isAlreadyInstalled(_ component: ComponentDefinition) -> Bool {
        let fm = FileManager.default

        switch component.installAction {
        case .brewInstall(let package):
            if shell.commandExists(package) { return true }
            return Homebrew(shell: shell, environment: environment).isPackageInstalled(package)

        case .mcpServer(let config):
            guard fm.fileExists(atPath: environment.claudeJSON.path) else { return false }
            do {
                let data = try Data(contentsOf: environment.claudeJSON)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let servers = json?[Constants.JSONKeys.mcpServers] as? [String: Any]
                return servers?[config.name] != nil
            } catch {
                return false
            }

        case .plugin(let name):
            guard fm.fileExists(atPath: environment.claudeSettings.path) else { return false }
            do {
                let settings = try Settings.load(from: environment.claudeSettings)
                return settings.enabledPlugins?[name] == true
            } catch {
                return false
            }

        case .shellCommand:
            // Handle components installed via shell commands that have a verifiable binary
            switch component.id {
            case "core.homebrew":
                return shell.commandExists("brew")
            case "core.claude-code":
                return shell.commandExists(Constants.CLI.claudeCommand)
            default:
                return false
            }

        case .gitignoreEntries:
            return false // Idempotent

        case .copySkill, .copyHook, .copyCommand, .settingsMerge:
            return false
        }
    }

    // MARK: - Pack Post-Processing

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
}
