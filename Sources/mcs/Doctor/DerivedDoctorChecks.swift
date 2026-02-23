import Foundation

// MARK: - Deriving doctor checks from ComponentDefinition

extension ComponentDefinition {
    /// Auto-generates doctor check(s) from installAction.
    /// Returns nil for actions that have no mechanical verification
    /// (e.g. .shellCommand, .settingsMerge, .gitignoreEntries).
    func deriveDoctorCheck() -> (any DoctorCheck)? {
        switch installAction {
        case .mcpServer(let config):
            return MCPServerCheck(name: displayName, serverName: config.name)

        case .plugin(let pluginName):
            return PluginCheck(pluginName: pluginName)

        case .brewInstall(let package):
            return CommandCheck(
                name: displayName,
                section: type.doctorSection,
                command: package,
                isOptional: !isRequired
            )

        case .copySkill(let source, let destination):
            return SkillFreshnessCheck(
                skillName: displayName,
                skillSource: source,
                skillDestination: destination
            )

        case .copyHook(_, let destination):
            return HookCheck(hookName: destination, isOptional: !isRequired)

        case .copyCommand(_, let destination, _):
            return CommandFileCheck(
                name: displayName,
                path: Environment().commandsDirectory.appendingPathComponent(destination)
            )

        case .copyPackFile(_, let destination, let fileType):
            let destURL = fileType.destinationURL(in: Environment(), destination: destination)
            return FileExistsCheck(
                name: displayName,
                section: type.doctorSection,
                path: destURL
            )

        case .shellCommand, .settingsMerge, .gitignoreEntries:
            return nil
        }
    }

    /// All doctor checks for this component: auto-derived + supplementary.
    func allDoctorChecks() -> [any DoctorCheck] {
        var checks: [any DoctorCheck] = []
        if let derived = deriveDoctorCheck() {
            checks.append(derived)
        }
        checks.append(contentsOf: supplementaryChecks)
        return checks
    }
}

// MARK: - Skill freshness check

/// Checks that a skill directory exists and its per-file hashes match
/// what the manifest recorded. Replaces the simple FileExistsCheck for skills.
struct SkillFreshnessCheck: DoctorCheck, Sendable {
    let skillName: String
    /// Relative path within the resources bundle (e.g. "skills/continuous-learning")
    let skillSource: String
    /// Destination directory name under skillsDirectory (e.g. "continuous-learning")
    let skillDestination: String

    var name: String { skillName }
    var section: String { "Skills" }

    func check() -> CheckResult {
        let env = Environment()
        let destDir = env.skillsDirectory.appendingPathComponent(skillDestination)

        guard FileManager.default.fileExists(atPath: destDir.path) else {
            return .fail("missing")
        }

        // Check if any per-file hashes are tracked in the manifest
        let manifest = Manifest(path: env.setupManifest)
        let prefix = "\(skillSource)/"
        let trackedFiles = manifest.trackedPaths.filter { $0.hasPrefix(prefix) }

        guard !trackedFiles.isEmpty else {
            return .warn("present but not hash-tracked — run 'mcs install' to refresh")
        }

        // Compare per-file hashes, detect missing and drifted files
        var drifted: [String] = []
        var missing: [String] = []
        for relativePath in trackedFiles {
            let fileName = String(relativePath.dropFirst(prefix.count))
            let installedFile = destDir.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: installedFile.path) {
                missing.append(fileName)
            } else if let matches = manifest.check(relativePath: relativePath, installedFile: installedFile),
                      !matches {
                drifted.append(fileName)
            }
        }

        if !missing.isEmpty {
            return .fail("missing files: \(missing.joined(separator: ", ")) — run 'mcs install' to restore")
        }
        if !drifted.isEmpty {
            return .warn("drifted: \(drifted.joined(separator: ", ")) — run 'mcs install' to refresh")
        }

        // Check if the bundled source has been updated since last install.
        // This catches the case where manifest and installed match (both from a previous version)
        // but the current binary ships with updated source.
        if let resourceURL = Bundle.module.url(forResource: "Resources", withExtension: nil)?
            .appendingPathComponent(skillSource),
           FileManager.default.fileExists(atPath: resourceURL.path),
           let sourceHashes = try? Manifest.directoryFileHashes(at: resourceURL) {
            var sourceOutdated: [String] = []
            for entry in sourceHashes {
                let manifestPath = "\(skillSource)/\(entry.relativePath)"
                if let manifestHash = manifest.sourceHash(for: manifestPath) {
                    if manifestHash != entry.hash {
                        sourceOutdated.append(entry.relativePath)
                    }
                } else {
                    // New file in bundled source not in manifest — source has been updated
                    sourceOutdated.append(entry.relativePath)
                }
            }
            if !sourceOutdated.isEmpty {
                return .warn("source updated in new mcs version — run 'mcs install' to refresh")
            }
        }

        return .pass("present, up to date")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to install or refresh skills")
    }
}
