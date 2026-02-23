import Foundation

/// Shared component installation logic used by both `Installer` (mcs install)
/// and `PackInstaller` (mcs configure). Eliminates duplication and ensures
/// consistent behavior across install paths.
struct ComponentExecutor {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner
    var backup: Backup

    // MARK: - Brew Packages

    /// Install a Homebrew package, or confirm it's already available.
    func installBrewPackage(_ package: String) -> Bool {
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

    // MARK: - MCP Servers

    /// Register an MCP server via the Claude CLI.
    func installMCPServer(_ config: MCPServerConfig) -> Bool {
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

    // MARK: - Plugins

    /// Install a plugin via the Claude CLI.
    func installPlugin(_ fullName: String) -> Bool {
        guard shell.commandExists(Constants.CLI.claudeCommand) else {
            output.warn("Claude Code CLI not found, skipping plugin")
            return false
        }
        let claude = ClaudeIntegration(shell: shell)
        let result = claude.pluginInstall(fullName: fullName)
        return result.succeeded
    }

    // MARK: - Gitignore

    /// Add entries to the global gitignore.
    func addGitignoreEntries(_ entries: [String]) -> Bool {
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

    // MARK: - Post-Install

    /// Run post-install steps for specific components (e.g., start services, pull models).
    func postInstall(_ component: ComponentDefinition) {
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

    // MARK: - Pack Post-Processing

    /// Inject a pack's hook contributions into installed hook files using section markers.
    mutating func injectHookContributions(from pack: any TechPack) {
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
    func addPackGitignoreEntries(from pack: any TechPack) {
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

    // MARK: - Already-Installed Detection

    /// Check if a component is already installed using the same derived + supplementary
    /// doctor checks used by `mcs doctor`, ensuring install and doctor always use
    /// the same detection logic.
    static func isAlreadyInstalled(_ component: ComponentDefinition) -> Bool {
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
}
