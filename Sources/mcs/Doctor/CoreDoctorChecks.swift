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

struct DeprecatedMCPServerCheck: DoctorCheck, Sendable {
    let name: String
    let section = "Migration"
    let identifier: String

    func check() -> CheckResult {
        let env = Environment()
        let claudeJSONPath = env.claudeJSON
        guard let data = try? Data(contentsOf: claudeJSONPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcpServers = json[Constants.JSONKeys.mcpServers] as? [String: Any],
              mcpServers[identifier] != nil
        else {
            return .pass("not present (good)")
        }

        guard SettingsOwnership.isOwnedByMCS(keyPath: "mcpServers.\(identifier)", env: env) else {
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

        guard SettingsOwnership.isOwnedByMCS(keyPath: "enabledPlugins.\(pluginName)", env: env) else {
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
}

// MARK: - Continuous Learning hook fragment check

/// Checks that the continuous learning fragment is injected into session_start.sh
/// with the current version marker. Uses the same `# --- mcs:begin learning v<version> ---`
/// section marker pattern used by tech pack hook contributions.
struct ContinuousLearningHookFragmentCheck: DoctorCheck, Sendable {
    var name: String { "Continuous learning hook fragment" }
    var section: String { "Hooks" }

    private let fragmentID = Constants.Hooks.continuousLearningFragmentID

    func check() -> CheckResult {
        let env = Environment()
        let hookFile = env.hooksDirectory.appendingPathComponent(Constants.FileNames.sessionStartHook)

        guard FileManager.default.fileExists(atPath: hookFile.path) else {
            return .skip("\(Constants.FileNames.sessionStartHook) not installed")
        }

        guard let content = try? String(contentsOf: hookFile, encoding: .utf8) else {
            return .fail("could not read \(Constants.FileNames.sessionStartHook)")
        }

        let expectedVersion = MCSVersion.current
        let versionedMarker = "# --- mcs:begin \(fragmentID) v\(expectedVersion) ---"
        let endMarker = "# --- mcs:end \(fragmentID) ---"

        // Check for current-version marker
        if content.contains(versionedMarker) {
            // Version matches — check content for drift
            if let beginRange = content.range(of: versionedMarker),
               let endRange = content.range(of: endMarker) {
                let installed = String(content[beginRange.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let expected = CoreComponents.continuousLearningHookFragment
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if installed == expected {
                    return .pass("v\(expectedVersion) up to date")
                }
                return .warn("v\(expectedVersion) content drifted — run 'mcs install' to refresh")
            }
            return .pass("v\(expectedVersion) injected")
        }

        // Check for any version or unversioned marker (outdated or legacy)
        let pattern = #"# --- mcs:begin learning( v[0-9]+\.[0-9]+\.[0-9]+)? ---"#
        if content.range(of: pattern, options: .regularExpression) != nil {
            if let installedVersion = parseInstalledVersion(from: content) {
                return .warn("v\(installedVersion) installed, v\(expectedVersion) available — run 'mcs install'")
            }
            return .warn("unversioned fragment installed, v\(expectedVersion) available — run 'mcs install'")
        }

        // No marker at all — fragment was never injected (optional feature)
        return .skip("not injected (continuous learning not selected)")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' and select Continuous Learning to inject the fragment")
    }

    private func parseInstalledVersion(from content: String) -> String? {
        let pattern = #"# --- mcs:begin learning v([0-9]+\.[0-9]+\.[0-9]+) ---"#
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
