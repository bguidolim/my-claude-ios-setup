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

        // Settings
        checks.append(SettingsCheck())

        // Gitignore
        checks.append(GitignoreCheck())

        // File Freshness
        checks.append(ManifestFreshnessCheck())

        // Migration (includes deprecated components + migration detectors)
        checks.append(DeprecatedMCPServerCheck(
            name: "Serena MCP", identifier: "serena"
        ))
        checks.append(DeprecatedPluginCheck(
            name: "claude-hud plugin", pluginName: "claude-hud@claude-hud"
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
        var missing: [String] = []
        for entry in GitignoreManager.coreEntries {
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
        let claudeJSONPath = Environment().claudeJSON
        guard let data = try? Data(contentsOf: claudeJSONPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcpServers = json["mcpServers"] as? [String: Any],
              mcpServers[identifier] != nil
        else {
            return .pass("not present (good)")
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
}

struct DeprecatedPluginCheck: DoctorCheck, Sendable {
    let name: String
    let section = "Migration"
    let pluginName: String

    func check() -> CheckResult {
        let settingsURL = Environment().claudeSettings
        guard let settings = try? Settings.load(from: settingsURL) else {
            return .pass("no settings file")
        }
        if settings.enabledPlugins?[pluginName] == true {
            return .warn("deprecated '\(pluginName)' still enabled — remove it")
        }
        return .pass("not present (good)")
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
}
