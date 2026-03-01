import Foundation

/// Discovers existing Claude Code configuration artifacts from live config files.
/// This is the "read" side of the export wizard — it scans settings, MCP servers,
/// .claude/ directories, CLAUDE.md sections, and gitignore to build a complete
/// picture of what's currently configured.
struct ConfigurationDiscovery: Sendable {
    let environment: Environment
    let output: CLIOutput

    // MARK: - Discovered Artifact Models

    struct DiscoveredConfiguration: Sendable {
        var mcpServers: [DiscoveredMCPServer] = []
        var hookFiles: [DiscoveredFile] = []
        var skillFiles: [DiscoveredFile] = []
        var commandFiles: [DiscoveredFile] = []
        var plugins: [String] = []
        var claudeSections: [DiscoveredClaudeSection] = []
        var claudeUserContent: String?
        var gitignoreEntries: [String] = []
        /// Remaining settings (non-hook, non-plugin) as serialized JSON data.
        /// Stored as `Data` for Sendable compliance.
        var remainingSettingsData: Data?

        var isEmpty: Bool {
            mcpServers.isEmpty && hookFiles.isEmpty && skillFiles.isEmpty
            && commandFiles.isEmpty && plugins.isEmpty && claudeSections.isEmpty
            && claudeUserContent == nil && gitignoreEntries.isEmpty
            && remainingSettingsData == nil
        }
    }

    struct DiscoveredMCPServer: Sendable {
        let name: String
        let command: String?
        let args: [String]
        let env: [String: String]
        let url: String?
        let scope: String

        var isHTTP: Bool { url != nil }
    }

    struct DiscoveredFile: Sendable {
        let filename: String
        let absolutePath: URL
        let hookEvent: String?

        init(filename: String, absolutePath: URL, hookEvent: String? = nil) {
            self.filename = filename
            self.absolutePath = absolutePath
            self.hookEvent = hookEvent
        }
    }

    struct DiscoveredClaudeSection: Sendable {
        let sectionIdentifier: String
        let content: String
    }

    // MARK: - Scope Configuration

    /// Where to discover: global (~/.claude/) or project (<project>/.claude/).
    enum Scope {
        case global
        case project(URL)
    }

    // MARK: - Discovery

    /// Discover all configuration artifacts for the given scope.
    func discover(scope: Scope) -> DiscoveredConfiguration {
        var config = DiscoveredConfiguration()

        let settingsPath: URL
        let claudeFilePath: URL
        let hooksDir: URL
        let skillsDir: URL
        let commandsDir: URL

        switch scope {
        case .global:
            settingsPath = environment.claudeSettings
            claudeFilePath = environment.globalClaudeMD
            hooksDir = environment.hooksDirectory
            skillsDir = environment.skillsDirectory
            commandsDir = environment.commandsDirectory
        case .project(let projectRoot):
            let claudeDir = projectRoot.appendingPathComponent(Constants.FileNames.claudeDirectory)
            settingsPath = claudeDir.appendingPathComponent("settings.local.json")
            claudeFilePath = projectRoot.appendingPathComponent(Constants.FileNames.claudeLocalMD)
            hooksDir = claudeDir.appendingPathComponent("hooks")
            skillsDir = claudeDir.appendingPathComponent("skills")
            commandsDir = claudeDir.appendingPathComponent("commands")
        }

        // 1. Discover MCP servers from ~/.claude.json
        discoverMCPServers(scope: scope, into: &config)

        // 2. Discover settings (hooks, plugins, remaining keys)
        discoverSettings(at: settingsPath, hooksDir: hooksDir, into: &config)

        // 3. Discover files in .claude/ subdirectories
        discoverFiles(in: hooksDir, hookCommands: config.hookFiles.isEmpty ? extractHookCommands(at: settingsPath) : nil, into: &config)
        config.skillFiles = listFiles(in: skillsDir)
        config.commandFiles = listFiles(in: commandsDir)

        // 4. Discover CLAUDE.md content
        discoverClaudeContent(at: claudeFilePath, into: &config)

        // 5. Discover gitignore entries (global scope only)
        if case .global = scope {
            discoverGitignoreEntries(into: &config)
        }

        return config
    }

    // MARK: - MCP Server Discovery

    private func discoverMCPServers(scope: Scope, into config: inout DiscoveredConfiguration) {
        let claudeJSONPath = environment.claudeJSON
        guard FileManager.default.fileExists(atPath: claudeJSONPath.path),
              let data = try? Data(contentsOf: claudeJSONPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        switch scope {
        case .global:
            // Read top-level mcpServers (global/user scope)
            if let servers = json[Constants.JSONKeys.mcpServers] as? [String: Any] {
                for (name, value) in servers {
                    if let serverDict = value as? [String: Any] {
                        config.mcpServers.append(parseMCPServer(name: name, dict: serverDict, scope: "user"))
                    }
                }
            }
        case .project(let projectRoot):
            // Read project-scoped servers from projects[path].mcpServers
            if let projects = json[Constants.JSONKeys.projects] as? [String: Any],
               let projectEntry = projects[projectRoot.path] as? [String: Any],
               let servers = projectEntry[Constants.JSONKeys.mcpServers] as? [String: Any] {
                for (name, value) in servers {
                    if let serverDict = value as? [String: Any] {
                        config.mcpServers.append(parseMCPServer(name: name, dict: serverDict, scope: "local"))
                    }
                }
            }
        }

        config.mcpServers.sort { $0.name < $1.name }
    }

    private func parseMCPServer(name: String, dict: [String: Any], scope: String) -> DiscoveredMCPServer {
        let command = dict["command"] as? String
        let args = dict["args"] as? [String] ?? []
        let envDict = dict["env"] as? [String: String] ?? [:]
        let url = dict["url"] as? String

        return DiscoveredMCPServer(
            name: name,
            command: command,
            args: args,
            env: envDict,
            url: url,
            scope: scope
        )
    }

    // MARK: - Settings Discovery

    private func discoverSettings(at settingsPath: URL, hooksDir: URL, into config: inout DiscoveredConfiguration) {
        guard let settings = try? Settings.load(from: settingsPath) else { return }

        // Extract plugins
        if let plugins = settings.enabledPlugins {
            config.plugins = plugins.filter { $0.value }.map(\.key).sorted()
        }

        // Build remaining settings (excluding hooks and enabledPlugins, which
        // auto-derive from components). Serialize as JSON Data for Sendable safety.
        var remaining: [String: Any] = [:]
        for (key, data) in settings.extraJSON {
            if let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
                remaining[key] = value
            }
        }
        if !remaining.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: remaining, options: [.prettyPrinted, .sortedKeys]) {
            config.remainingSettingsData = data
        }
    }

    /// Extract hook command → event mappings from settings, used to correlate
    /// discovered hook files with their Claude Code events.
    private func extractHookCommands(at settingsPath: URL) -> [String: String] {
        guard let settings = try? Settings.load(from: settingsPath),
              let hooks = settings.hooks else {
            return [:]
        }

        var commandToEvent: [String: String] = [:]
        for (event, groups) in hooks {
            for group in groups {
                for entry in group.hooks ?? [] {
                    if let command = entry.command {
                        commandToEvent[command] = event
                    }
                }
            }
        }
        return commandToEvent
    }

    // MARK: - File Discovery

    private func discoverFiles(in hooksDir: URL, hookCommands: [String: String]?, into config: inout DiscoveredConfiguration) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hooksDir.path),
              let files = try? fm.contentsOfDirectory(at: hooksDir, includingPropertiesForKeys: nil) else {
            return
        }

        let commandToEvent = hookCommands ?? [:]

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let filename = file.lastPathComponent
            guard !filename.hasPrefix(".") else { continue }

            // Try to match this file to a hook event via settings commands
            var matchedEvent: String?
            for (command, event) in commandToEvent {
                if command.contains(filename) {
                    matchedEvent = event
                    break
                }
            }

            config.hookFiles.append(DiscoveredFile(
                filename: filename,
                absolutePath: file,
                hookEvent: matchedEvent
            ))
        }
    }

    private func listFiles(in directory: URL) -> [DiscoveredFile] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path),
              let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            return []
        }

        return files
            .filter { url in
                let name = url.lastPathComponent
                guard !name.hasPrefix(".") else { return false }
                // Skip broken symlinks — they can't be copied to the output pack
                if let vals = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                   vals.isSymbolicLink == true {
                    let resolved = url.resolvingSymlinksInPath()
                    if !fm.fileExists(atPath: resolved.path) {
                        output.warn("  Skipping broken symlink: \(name)")
                        return false
                    }
                }
                return true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { DiscoveredFile(filename: $0.lastPathComponent, absolutePath: $0) }
    }

    // MARK: - CLAUDE.md Discovery

    private func discoverClaudeContent(at path: URL, into config: inout DiscoveredConfiguration) {
        guard let content = try? String(contentsOf: path, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Parse managed sections
        let sections = TemplateComposer.parseSections(from: content)
        for section in sections {
            config.claudeSections.append(DiscoveredClaudeSection(
                sectionIdentifier: section.identifier,
                content: section.content
            ))
        }

        // Extract user content (outside any section markers)
        let userContent = TemplateComposer.extractUserContent(from: content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !userContent.isEmpty {
            config.claudeUserContent = userContent
        }
    }

    // MARK: - Gitignore Discovery

    private func discoverGitignoreEntries(into config: inout DiscoveredConfiguration) {
        let gitignoreManager = GitignoreManager(shell: ShellRunner(environment: environment))
        let gitignoreURL = gitignoreManager.resolveGlobalGitignorePath()

        guard let content = try? String(contentsOf: gitignoreURL, encoding: String.Encoding.utf8) else { return }

        // Filter out mcs core entries (those are auto-managed)
        let coreEntries = Set(GitignoreManager.coreEntries)
        let entries = content
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !coreEntries.contains($0) }

        config.gitignoreEntries = entries
    }
}

// MARK: - Sensitive Env Var Detection

extension ConfigurationDiscovery.DiscoveredMCPServer {
    /// Names of env vars that likely contain secrets.
    static let sensitivePatterns = ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "API_KEY"]

    /// Returns env var names that appear to contain sensitive values.
    var sensitiveEnvVarNames: [String] {
        env.keys.filter { name in
            let upper = name.uppercased()
            return Self.sensitivePatterns.contains { upper.contains($0) }
        }.sorted()
    }
}
