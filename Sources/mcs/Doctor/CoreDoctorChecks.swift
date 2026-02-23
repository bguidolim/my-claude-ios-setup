import Foundation

// MARK: - Check implementations
//
// ## fix() Responsibility Boundaries
//
// `doctor --fix` handles only:
// - **Cleanup**: Removing deprecated components (MCP servers, plugins, legacy files)
// - **Migration**: One-time data moves (memories, state files, shell RC entries)
// - **Trivial repairs**: Permission fixes (chmod), gitignore additions (idempotent)
//
// `doctor --fix` does NOT handle:
// - **Additive operations**: Installing packages, registering servers, copying hooks/skills/commands.
//   These are `mcs install`'s responsibility because only install manages the manifest
//   (the system's source of truth for what's installed and at what hash).
//
// This separation prevents inconsistent state where a file is present but
// the manifest doesn't know about it, causing repeated false doctor warnings.

struct CommandCheck: DoctorCheck, Sendable {
    let name: String
    let section: String
    let command: String
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
        .notFixable("Run 'mcs install' to install dependencies")
    }
}

/// Supplementary check for Ollama's daemon and model state.
/// Used as a supplementaryCheck on the core.ollama component.
/// Binary existence is handled by the auto-derived CommandCheck.
struct OllamaRuntimeCheck: DoctorCheck, Sendable {
    var name: String { "Ollama runtime" }
    var section: String { "Dependencies" }

    func check() -> CheckResult {
        let env = Environment()
        let shell = ShellRunner(environment: env)
        let ollama = OllamaService(shell: shell, environment: env)

        guard shell.commandExists("ollama") else {
            return .skip("ollama not installed")
        }
        guard ollama.isRunning() else {
            return .warn("not running — start with 'ollama serve' or open the Ollama app")
        }
        guard ollama.hasEmbeddingModel() else {
            return .warn("running but \(Constants.Ollama.embeddingModel) model not installed — run 'ollama pull \(Constants.Ollama.embeddingModel)'")
        }
        return .pass("running with \(Constants.Ollama.embeddingModel)")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to configure Ollama")
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
        let data: Data
        do {
            data = try Data(contentsOf: claudeJSONPath)
        } catch {
            return .fail("cannot read ~/.claude.json: \(error.localizedDescription)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .fail("~/.claude.json contains invalid JSON")
        }
        guard let mcpServers = json[Constants.JSONKeys.mcpServers] as? [String: Any],
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
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return .fail("settings.json not found")
        }
        let settings: Settings
        do {
            settings = try Settings.load(from: settingsURL)
        } catch {
            return .fail("settings.json is invalid: \(error.localizedDescription)")
        }
        if settings.enabledPlugins?[pluginName] == true {
            return .pass("enabled")
        }
        return .fail("not enabled")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to install plugins")
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
    var isOptional: Bool = false

    var name: String { hookName }
    var section: String { "Hooks" }

    func check() -> CheckResult {
        let hookPath = Environment().hooksDirectory.appendingPathComponent(hookName)
        guard FileManager.default.fileExists(atPath: hookPath.path) else {
            return isOptional ? .skip("not installed (optional)") : .fail("missing")
        }
        guard FileManager.default.isExecutableFile(atPath: hookPath.path) else {
            return .fail("not executable")
        }
        return .pass("present and executable")
    }

    func fix() -> FixResult {
        let env = Environment()
        let hookPath = env.hooksDirectory.appendingPathComponent(hookName)
        let fm = FileManager.default

        // Only fix permissions — additive operations (installing/replacing hooks) are
        // handled by `mcs install`, which also records manifest hashes.
        guard fm.fileExists(atPath: hookPath.path) else {
            return .notFixable("Run 'mcs install' to install hooks")
        }

        if !fm.isExecutableFile(atPath: hookPath.path) {
            do {
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath.path)
                return .fixed("made executable")
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        return .notFixable("Run 'mcs install' to reinstall hooks")
    }
}

struct HookEventCheck: DoctorCheck, Sendable {
    let eventName: String
    var isOptional: Bool = false

    var name: String { "\(eventName) hook event" }
    var section: String { "Hooks" }

    func check() -> CheckResult {
        let settingsURL = Environment().claudeSettings
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return .fail("settings.json not found")
        }
        let settings: Settings
        do {
            settings = try Settings.load(from: settingsURL)
        } catch {
            return .fail("settings.json is invalid: \(error.localizedDescription)")
        }
        guard let hooks = settings.hooks, hooks[eventName] != nil else {
            return isOptional
                ? .skip("\(eventName) not registered (optional)")
                : .fail("\(eventName) not registered in settings.json")
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
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return .fail("settings.json not found")
        }
        let settings: Settings
        do {
            settings = try Settings.load(from: settingsURL)
        } catch {
            return .fail("settings.json is invalid: \(error.localizedDescription)")
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
    let registry: TechPackRegistry

    init(registry: TechPackRegistry = .shared) {
        self.registry = registry
    }

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
            + registry.gitignoreEntries(installedPacks: manifest.installedPacks)
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
            for entry in registry.gitignoreEntries(installedPacks: manifest.installedPacks) {
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

    /// The marker that v2 managed command files contain.
    static let managedMarker = "<!-- mcs:managed -->"

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
        // Verify file has the managed marker (v2+ format)
        if !content.contains(Self.managedMarker) {
            return .warn("legacy format — run 'mcs install' to update")
        }
        return .pass("present")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to install, or 'mcs configure' to fill placeholders")
    }
}

