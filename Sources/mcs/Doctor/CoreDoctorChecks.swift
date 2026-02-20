import Foundation

// MARK: - Core checks factory

extension DoctorRunner {
    func coreDoctorChecks() -> [any DoctorCheck] {
        var checks: [any DoctorCheck] = []

        // Dependencies
        checks.append(CommandCheck(
            name: "Homebrew", section: "Dependencies", command: "brew", fixAction: nil
        ))
        checks.append(CommandCheck(
            name: "Node.js", section: "Dependencies", command: "node",
            fixAction: "brew install node"
        ))
        checks.append(CommandCheck(
            name: "jq", section: "Dependencies", command: "jq",
            fixAction: "brew install jq"
        ))
        checks.append(CommandCheck(
            name: "Claude Code", section: "Dependencies", command: "claude", fixAction: nil
        ))
        checks.append(CommandCheck(
            name: "GitHub CLI", section: "Dependencies", command: "gh",
            fixAction: "brew install gh", isOptional: true
        ))
        checks.append(OllamaCheck())

        // MCP Servers
        checks.append(MCPServerCheck(name: "docs-mcp-server", serverName: "docs-mcp-server"))

        // Plugins
        for pluginName in [
            "explanatory-output-style@claude-plugins-official",
            "pr-review-toolkit@claude-plugins-official",
            "ralph-loop@claude-plugins-official",
            "claude-md-management@claude-plugins-official",
        ] {
            checks.append(PluginCheck(pluginName: pluginName))
        }

        // Skills
        let env = Environment()
        checks.append(FileExistsCheck(
            name: "continuous-learning skill",
            section: "Skills",
            path: env.skillsDirectory.appendingPathComponent("continuous-learning/SKILL.md")
        ))

        // Commands
        checks.append(CommandFileCheck(
            name: "/pr command",
            path: env.commandsDirectory.appendingPathComponent("pr.md")
        ))

        // Hooks
        checks.append(HookCheck(hookName: "session_start.sh"))
        checks.append(HookCheck(hookName: "continuous-learning-activator.sh"))
        checks.append(HookEventCheck(eventName: "SessionStart"))
        checks.append(HookEventCheck(eventName: "UserPromptSubmit"))

        // Settings
        checks.append(SettingsCheck())
        checks.append(SettingsOwnershipCheck())

        // Gitignore
        checks.append(GitignoreCheck())

        // File Freshness
        checks.append(ManifestFreshnessCheck())

        // Migration (includes deprecated components + migration detectors)
        checks.append(DeprecatedMCPServerCheck(
            name: "Serena MCP", identifier: "serena"
        ))
        checks.append(DeprecatedMCPServerCheck(
            name: "mcp-omnisearch", identifier: "mcp-omnisearch"
        ))
        checks.append(DeprecatedPluginCheck(
            name: "claude-hud plugin", pluginName: "claude-hud@claude-hud"
        ))
        checks.append(DeprecatedPluginCheck(
            name: "code-simplifier plugin",
            pluginName: "code-simplifier@claude-plugins-official"
        ))
        checks.append(contentsOf: MigrationDetector.checks)

        return checks
    }
}

// MARK: - Check implementations

struct CommandCheck: DoctorCheck, Sendable {
    let name: String
    let section: String
    let command: String
    let fixAction: String?
    var isOptional: Bool = false

    func check() -> CheckResult {
        let shell = ShellRunner(environment: Environment())
        if shell.commandExists(command) {
            return .pass("installed")
        }
        if isOptional {
            return .warn("not found (optional)")
        }
        return .fail("not found")
    }

    func fix() -> FixResult {
        guard let action = fixAction else {
            return .notFixable("Install \(name) manually")
        }
        let shell = ShellRunner(environment: Environment())
        let result = shell.shell(action)
        return result.succeeded ? .fixed("installed \(name)") : .failed(result.stderr)
    }
}

struct OllamaCheck: DoctorCheck, Sendable {
    var name: String { "Ollama" }
    var section: String { "Dependencies" }

    func check() -> CheckResult {
        let shell = ShellRunner(environment: Environment())

        // Check installed
        guard shell.commandExists("ollama") else {
            return .fail("not installed")
        }
        // Check running
        let curlResult = shell.shell("curl -s --max-time 2 http://localhost:11434/api/tags")
        guard curlResult.succeeded else {
            return .fail("installed but not running")
        }
        // Check model
        let modelResult = shell.run("/usr/bin/env", arguments: ["ollama", "list"])
        guard modelResult.stdout.contains("nomic-embed-text") else {
            return .fail("running but nomic-embed-text model not installed")
        }
        return .pass("running with nomic-embed-text")
    }

    func fix() -> FixResult {
        let env = Environment()
        let shell = ShellRunner(environment: env)
        let brew = Homebrew(shell: shell, environment: env)

        guard shell.commandExists("ollama") else {
            return .notFixable("Install Ollama via: brew install ollama")
        }

        // Try to start if not running
        let curlResult = shell.shell("curl -s --max-time 2 http://localhost:11434/api/tags")
        if !curlResult.succeeded {
            brew.startService("ollama")
            // Wait for Ollama to start
            for _ in 0..<30 {
                let r = shell.shell("curl -s --max-time 2 http://localhost:11434/api/tags")
                if r.succeeded { break }
                Thread.sleep(forTimeInterval: 1)
            }
        }

        // Pull model if missing
        let modelResult = shell.run("/usr/bin/env", arguments: ["ollama", "list"])
        if !modelResult.stdout.contains("nomic-embed-text") {
            shell.run("/usr/bin/env", arguments: ["ollama", "pull", "nomic-embed-text"])
        }
        return .fixed("Ollama started and model pulled")
    }
}

struct MCPServerCheck: DoctorCheck, Sendable {
    let name: String
    let section = "MCP Servers"
    let serverName: String

    func check() -> CheckResult {
        let claudeJSONPath = Environment().claudeJSON
        guard FileManager.default.fileExists(atPath: claudeJSONPath.path) else {
            return .fail("~/.claude.json not found")
        }
        guard let data = try? Data(contentsOf: claudeJSONPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcpServers = json["mcpServers"] as? [String: Any],
              mcpServers[serverName] != nil
        else {
            return .fail("not registered")
        }
        return .pass("registered")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to register MCP servers")
    }
}

struct PluginCheck: DoctorCheck, Sendable {
    let pluginName: String
    var name: String { pluginName.components(separatedBy: "@").first ?? pluginName }
    var section: String { "Plugins" }

    func check() -> CheckResult {
        let settingsURL = Environment().claudeSettings
        guard let settings = try? Settings.load(from: settingsURL) else {
            return .fail("settings.json not found")
        }
        if settings.enabledPlugins?[pluginName] == true {
            return .pass("enabled")
        }
        return .fail("not enabled")
    }

    func fix() -> FixResult {
        let shell = ShellRunner(environment: Environment())
        let claude = ClaudeIntegration(shell: shell)
        let result = claude.pluginInstall(fullName: pluginName)
        if result.succeeded {
            return .fixed("installed \(name)")
        }
        return .failed(result.stderr)
    }
}

struct FileExistsCheck: DoctorCheck, Sendable {
    let name: String
    let section: String
    let path: URL

    func check() -> CheckResult {
        FileManager.default.fileExists(atPath: path.path) ? .pass("present") : .fail("missing")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to install")
    }
}

struct HookCheck: DoctorCheck, Sendable {
    let hookName: String

    var name: String { hookName }
    var section: String { "Hooks" }

    func check() -> CheckResult {
        let hookPath = Environment().hooksDirectory.appendingPathComponent(hookName)
        guard FileManager.default.fileExists(atPath: hookPath.path) else {
            return .fail("missing")
        }
        guard FileManager.default.isExecutableFile(atPath: hookPath.path) else {
            return .fail("not executable")
        }
        return .pass("present and executable")
    }

    func fix() -> FixResult {
        let hookPath = Environment().hooksDirectory.appendingPathComponent(hookName)
        if FileManager.default.fileExists(atPath: hookPath.path) {
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: hookPath.path
                )
                return .fixed("made executable")
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return .notFixable("Run 'mcs install' to install hooks")
    }
}

struct HookEventCheck: DoctorCheck, Sendable {
    let eventName: String

    var name: String { "\(eventName) hook event" }
    var section: String { "Hooks" }

    func check() -> CheckResult {
        let settingsURL = Environment().claudeSettings
        guard let settings = try? Settings.load(from: settingsURL) else {
            return .fail("settings.json not found")
        }
        guard let hooks = settings.hooks, hooks[eventName] != nil else {
            return .fail("\(eventName) not registered in settings.json")
        }
        return .pass("registered in settings.json")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to merge settings")
    }
}

struct SettingsCheck: DoctorCheck, Sendable {
    var name: String { "Claude settings" }
    var section: String { "Settings" }

    func check() -> CheckResult {
        let settingsURL = Environment().claudeSettings
        guard let settings = try? Settings.load(from: settingsURL) else {
            return .fail("settings.json not found or invalid")
        }
        var issues: [String] = []
        if settings.permissions?.defaultMode != "plan" {
            issues.append("defaultMode not set to 'plan'")
        }
        if settings.alwaysThinkingEnabled != true {
            issues.append("alwaysThinkingEnabled not set")
        }
        if issues.isEmpty {
            return .pass("configured correctly")
        }
        return .warn(issues.joined(separator: "; "))
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to merge settings")
    }
}

struct SettingsOwnershipCheck: DoctorCheck, Sendable {
    var name: String { "Settings ownership" }
    var section: String { "Settings" }

    func check() -> CheckResult {
        let env = Environment()
        let ownership = SettingsOwnership(path: env.settingsKeys)

        guard !ownership.managedKeys.isEmpty else {
            return .skip("no ownership sidecar — run 'mcs install' to create")
        }

        // Load current template to find stale keys
        guard let resourceURL = Bundle.module.url(forResource: "Resources", withExtension: nil)
        else {
            return .skip("resources bundle not found")
        }

        let templateURL = resourceURL
            .appendingPathComponent("config")
            .appendingPathComponent("settings.json")
        guard let template = try? Settings.load(from: templateURL) else {
            return .skip("could not load settings template")
        }

        let stale = ownership.staleKeys(comparedTo: template)
        if stale.isEmpty {
            return .pass("\(ownership.managedKeys.count) managed key(s), none stale")
        }
        return .warn("\(stale.count) stale key(s): \(stale.joined(separator: ", "))")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to clean up stale settings")
    }
}

struct GitignoreCheck: DoctorCheck, Sendable {
    var name: String { "Global gitignore" }
    var section: String { "Gitignore" }

    func check() -> CheckResult {
        let shell = ShellRunner(environment: Environment())
        let gitignoreManager = GitignoreManager(shell: shell)
        let gitignorePath = gitignoreManager.resolveGlobalGitignorePath()
        guard FileManager.default.fileExists(atPath: gitignorePath.path),
              let content = try? String(contentsOf: gitignorePath, encoding: .utf8)
        else {
            return .fail("global gitignore not found")
        }
        // Check core entries + installed pack gitignore entries
        let manifest = Manifest(path: Environment().setupManifest)
        let allEntries = GitignoreManager.coreEntries
            + TechPackRegistry.shared.gitignoreEntries(installedPacks: manifest.installedPacks)
        var missing: [String] = []
        for entry in allEntries {
            if !content.contains(entry) {
                missing.append(entry)
            }
        }
        if missing.isEmpty {
            return .pass("all entries present")
        }
        return .fail("missing entries: \(missing.joined(separator: ", "))")
    }

    func fix() -> FixResult {
        let shell = ShellRunner(environment: Environment())
        let gitignoreManager = GitignoreManager(shell: shell)
        do {
            try gitignoreManager.addCoreEntries()
            // Also add installed pack entries
            let manifest = Manifest(path: Environment().setupManifest)
            for entry in TechPackRegistry.shared.gitignoreEntries(installedPacks: manifest.installedPacks) {
                try gitignoreManager.addEntry(entry)
            }
            return .fixed("added missing entries")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

struct CommandFileCheck: DoctorCheck, Sendable {
    let name: String
    let section = "Commands"
    let path: URL

    func check() -> CheckResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            return .fail("missing")
        }
        guard let content = try? String(contentsOf: path, encoding: .utf8) else {
            return .fail("could not read file")
        }
        if content.contains("__BRANCH_PREFIX__") {
            return .warn("present but contains unreplaced __BRANCH_PREFIX__ placeholder")
        }
        return .pass("present")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to install, or 'mcs configure-project' to fill placeholders")
    }
}

struct DeprecatedMCPServerCheck: DoctorCheck, Sendable {
    let name: String
    let section = "Migration"
    let identifier: String

    func check() -> CheckResult {
        let env = Environment()
        let claudeJSONPath = env.claudeJSON
        guard let data = try? Data(contentsOf: claudeJSONPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcpServers = json["mcpServers"] as? [String: Any],
              mcpServers[identifier] != nil
        else {
            return .pass("not present (good)")
        }

        // Only warn if we own it (old installer or mcs installed it)
        guard isOwnedByMCS(env: env) else {
            return .pass("present (user-managed, not flagged)")
        }

        return .warn("deprecated '\(identifier)' still registered — remove it")
    }

    func fix() -> FixResult {
        let shell = ShellRunner(environment: Environment())
        let claude = ClaudeIntegration(shell: shell)
        let result = claude.mcpRemove(name: identifier)
        if result.succeeded {
            return .fixed("removed deprecated \(identifier)")
        }
        return .failed(result.stderr)
    }

    private func isOwnedByMCS(env: Environment) -> Bool {
        var ownership = SettingsOwnership(path: env.settingsKeys)
        // If sidecar doesn't exist yet, try bootstrapping from legacy manifest
        if ownership.managedKeys.isEmpty {
            ownership.bootstrapFromLegacyManifest(at: env.setupManifest)
        }
        return ownership.owns(keyPath: "mcpServers.\(identifier)")
    }
}

struct DeprecatedPluginCheck: DoctorCheck, Sendable {
    let name: String
    let section = "Migration"
    let pluginName: String

    func check() -> CheckResult {
        let env = Environment()
        let settingsURL = env.claudeSettings
        guard let settings = try? Settings.load(from: settingsURL) else {
            return .pass("no settings file")
        }
        guard settings.enabledPlugins?[pluginName] == true else {
            return .pass("not present (good)")
        }

        // Only warn if we own it (old installer or mcs installed it)
        guard isOwnedByMCS(env: env) else {
            return .pass("present (user-managed, not flagged)")
        }

        return .warn("deprecated '\(pluginName)' still enabled — remove it")
    }

    func fix() -> FixResult {
        let shell = ShellRunner(environment: Environment())
        let claude = ClaudeIntegration(shell: shell)
        let result = claude.pluginRemove(fullName: pluginName)
        if result.succeeded {
            return .fixed("removed deprecated \(pluginName)")
        }
        return .failed(result.stderr)
    }

    private func isOwnedByMCS(env: Environment) -> Bool {
        var ownership = SettingsOwnership(path: env.settingsKeys)
        if ownership.managedKeys.isEmpty {
            ownership.bootstrapFromLegacyManifest(at: env.setupManifest)
        }
        return ownership.owns(keyPath: "enabledPlugins.\(pluginName)")
    }
}

// MARK: - Pack migration adapter

/// Wraps a PackMigration as a DoctorCheck for integration with the doctor flow.
struct PackMigrationCheck: DoctorCheck, Sendable {
    let migration: any PackMigration
    let packName: String

    var name: String { "\(packName): \(migration.displayName)" }
    var section: String { "Migration" }

    func check() -> CheckResult {
        if migration.isNeeded() {
            return .warn("migration available: \(migration.displayName) (v\(migration.version))")
        }
        return .pass("up to date")
    }

    func fix() -> FixResult {
        guard migration.isNeeded() else {
            return .fixed("already up to date")
        }
        do {
            let description = try migration.perform()
            return .fixed(description)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - Hook contribution check

/// Checks that a pack's hook contribution has been injected into the installed hook file.
/// Compares both presence and version/content freshness using `MCSVersion.current`.
struct HookContributionCheck: DoctorCheck, Sendable {
    let packIdentifier: String
    let packDisplayName: String
    let contribution: HookContribution

    var name: String { "\(packDisplayName) hook (\(contribution.hookName))" }
    var section: String { "Hooks" }

    func check() -> CheckResult {
        let env = Environment()
        let hookFile = env.hooksDirectory
            .appendingPathComponent(contribution.hookName + ".sh")
        let fm = FileManager.default
        let expectedVersion = MCSVersion.current

        guard fm.fileExists(atPath: hookFile.path) else {
            return .skip("hook file \(contribution.hookName).sh not installed")
        }

        guard let content = try? String(contentsOf: hookFile, encoding: .utf8) else {
            return .fail("could not read \(contribution.hookName).sh")
        }

        // Check for current-version marker
        let versionedMarker = "# --- mcs:begin \(packIdentifier) v\(expectedVersion) ---"
        if content.contains(versionedMarker) {
            // Version matches — check content for drift
            let endMarker = "# --- mcs:end \(packIdentifier) ---"
            if let beginRange = content.range(of: versionedMarker),
               let endRange = content.range(of: endMarker) {
                let installed = String(content[beginRange.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let expected = contribution.scriptFragment
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if installed == expected {
                    return .pass("v\(expectedVersion) up to date")
                }
                return .warn("v\(expectedVersion) content drifted — run 'mcs install' to refresh")
            }
            return .pass("v\(expectedVersion) injected")
        }

        // Check for any version or unversioned marker (outdated or legacy)
        let pattern = #"# --- mcs:begin \#(packIdentifier)( v[0-9]+\.[0-9]+\.[0-9]+)? ---"#
        if content.range(of: pattern, options: .regularExpression) != nil {
            if let installedVersion = parseInstalledVersion(from: content) {
                return .warn("v\(installedVersion) installed, v\(expectedVersion) available — run 'mcs install'")
            }
            return .warn("unversioned fragment installed, v\(expectedVersion) available — run 'mcs install'")
        }

        return .fail("fragment not injected — run 'mcs install' to fix")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to inject hook contributions")
    }

    /// Extract the version from an installed marker like `# --- mcs:begin ios v1.0.0 ---`
    private func parseInstalledVersion(from content: String) -> String? {
        let pattern = #"# --- mcs:begin \#(packIdentifier) v([0-9]+\.[0-9]+\.[0-9]+) ---"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: content,
                  range: NSRange(content.startIndex..., in: content)
              ),
              match.numberOfRanges >= 2,
              let versionRange = Range(match.range(at: 1), in: content)
        else { return nil }
        return String(content[versionRange])
    }
}
