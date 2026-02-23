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

        let result = claude.mcpAdd(name: config.name, scope: config.resolvedScope, arguments: args)
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

    // MARK: - Copy Pack File

    /// Copy files from an external pack checkout to the appropriate Claude directory.
    mutating func installCopyPackFile(
        source: URL,
        destination: String,
        fileType: CopyFileType
    ) -> Bool {
        let fm = FileManager.default
        let destURL = fileType.destinationURL(in: environment, destination: destination)

        // Validate destination doesn't escape expected directory via symlinks
        let resolvedDest = destURL.resolvingSymlinksInPath()
        let expectedParent = fileType.baseDirectory(in: environment)
        let parentPath = expectedParent.resolvingSymlinksInPath().path
        let destPath = resolvedDest.path
        let parentPrefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        guard destPath.hasPrefix(parentPrefix) || destPath == parentPath else {
            output.warn("Destination '\(destination)' escapes expected directory")
            return false
        }

        guard fm.fileExists(atPath: source.path) else {
            output.warn("Pack source not found: \(source.path)")
            return false
        }

        do {
            try fm.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var isDir: ObjCBool = false
            fm.fileExists(atPath: source.path, isDirectory: &isDir)

            if isDir.boolValue {
                // Source is a directory — copy all files recursively
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                let contents = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
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
                    try fm.copyItem(at: file, to: destFile)
                }
            } else {
                // Source is a single file
                do {
                    try backup.backupFile(at: destURL)
                } catch {
                    output.warn("Could not backup \(destURL.lastPathComponent): \(error.localizedDescription)")
                }
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.copyItem(at: source, to: destURL)

                // Make hooks executable
                if fileType == .hook {
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destURL.path)
                }
            }
            return true
        } catch {
            output.warn(error.localizedDescription)
            return false
        }
    }

    // MARK: - Project-Scoped File Installation

    /// Copy a file or directory from an external pack into the project's `.claude/` tree.
    /// Returns the project-relative paths of installed files (for artifact tracking).
    mutating func installProjectFile(
        source: URL,
        destination: String,
        fileType: CopyFileType,
        projectPath: URL
    ) -> [String] {
        let fm = FileManager.default
        let baseDir = fileType.projectBaseDirectory(projectPath: projectPath)
        let destURL = baseDir.appendingPathComponent(destination)

        guard fm.fileExists(atPath: source.path) else {
            output.warn("Pack source not found: \(source.path)")
            return []
        }

        do {
            try fm.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var isDir: ObjCBool = false
            fm.fileExists(atPath: source.path, isDirectory: &isDir)
            var installedPaths: [String] = []

            if isDir.boolValue {
                try fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                let contents = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                for file in contents {
                    let destFile = destURL.appendingPathComponent(file.lastPathComponent)
                    if fm.fileExists(atPath: destFile.path) {
                        try fm.removeItem(at: destFile)
                    }
                    try fm.copyItem(at: file, to: destFile)
                    installedPaths.append(projectRelativePath(destFile, projectPath: projectPath))
                }
            } else {
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.copyItem(at: source, to: destURL)
                if fileType == .hook {
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destURL.path)
                }
                installedPaths.append(projectRelativePath(destURL, projectPath: projectPath))
            }
            return installedPaths
        } catch {
            output.warn(error.localizedDescription)
            return []
        }
    }

    /// Remove a file from the project by its project-relative path.
    func removeProjectFile(relativePath: String, projectPath: URL) {
        let fm = FileManager.default
        let fullPath = projectPath.appendingPathComponent(relativePath)
        if fm.fileExists(atPath: fullPath.path) {
            do {
                try fm.removeItem(at: fullPath)
            } catch {
                output.warn("Could not remove \(relativePath): \(error.localizedDescription)")
            }
        }
    }

    /// Remove an MCP server by name and scope.
    func removeMCPServer(name: String, scope: String) {
        let claude = ClaudeIntegration(shell: shell)
        claude.mcpRemove(name: name, scope: scope)
    }

    private func projectRelativePath(_ url: URL, projectPath: URL) -> String {
        let full = url.path
        let base = projectPath.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count))
        }
        return full
    }

    // MARK: - Already-Installed Detection

    /// Check if a component is already installed using the same derived + supplementary
    /// doctor checks used by `mcs doctor`, ensuring install and doctor always use
    /// the same detection logic.
    static func isAlreadyInstalled(_ component: ComponentDefinition) -> Bool {
        // Idempotent actions: always re-run
        switch component.installAction {
        case .settingsMerge, .gitignoreEntries, .copyPackFile:
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
