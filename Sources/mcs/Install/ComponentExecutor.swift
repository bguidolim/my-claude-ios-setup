import Foundation

/// Shared component installation logic used by `Installer`, `PackInstaller`,
/// and `ProjectConfigurator`. Eliminates duplication and ensures consistent
/// behavior across install paths.
struct ComponentExecutor {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner

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
        let ref = PluginRef(fullName)
        let result = claude.pluginInstall(ref: ref)
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
    func installCopyPackFile(
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
                    if fm.fileExists(atPath: destFile.path) {
                        try fm.removeItem(at: destFile)
                    }
                    try fm.copyItem(at: file, to: destFile)
                }
            } else {
                // Source is a single file
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
    /// Text files are run through the template engine so `__PLACEHOLDER__` tokens
    /// are replaced with resolved prompt values.
    /// Returns the project-relative paths of installed files (for artifact tracking).
    mutating func installProjectFile(
        source: URL,
        destination: String,
        fileType: CopyFileType,
        projectPath: URL,
        resolvedValues: [String: String] = [:]
    ) -> [String] {
        let fm = FileManager.default
        let baseDir = fileType.projectBaseDirectory(projectPath: projectPath)
        let destURL = baseDir.appendingPathComponent(destination)

        // Validate destination doesn't escape expected directory via symlinks
        let resolvedDest = destURL.resolvingSymlinksInPath()
        let expectedParent = baseDir.resolvingSymlinksInPath()
        let parentPath = expectedParent.path
        let destPath = resolvedDest.path
        let parentPrefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        guard destPath.hasPrefix(parentPrefix) || destPath == parentPath else {
            output.warn("Destination '\(destination)' escapes project directory")
            return []
        }

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
                    try Self.copyWithSubstitution(from: file, to: destFile, values: resolvedValues)
                    installedPaths.append(projectRelativePath(destFile, projectPath: projectPath))
                }
            } else {
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try Self.copyWithSubstitution(from: source, to: destURL, values: resolvedValues)
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

    /// Copy a file, substituting `__PLACEHOLDER__` values in text files.
    /// Falls back to binary copy for non-UTF-8 files or when no values are provided.
    static func copyWithSubstitution(
        from source: URL,
        to destination: URL,
        values: [String: String]
    ) throws {
        if !values.isEmpty {
            // Read as Data first to surface I/O errors (permission, disk),
            // then attempt UTF-8 decode to detect binary vs text files.
            let data = try Data(contentsOf: source)
            if let text = String(data: data, encoding: .utf8) {
                let substituted = TemplateEngine.substitute(template: text, values: values)
                try substituted.write(to: destination, atomically: true, encoding: .utf8)
                return
            }
        }
        // Binary file or no values to substitute
        try FileManager.default.copyItem(at: source, to: destination)
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
        // Convergent actions: always re-run to pick up config changes
        switch component.installAction {
        case .settingsMerge, .gitignoreEntries, .copyPackFile, .mcpServer:
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
