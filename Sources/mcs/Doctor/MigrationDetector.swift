import Foundation

/// Doctor checks that detect migration needs from older installations.
enum MigrationDetector {
    static var checks: [any DoctorCheck] {
        [
            LegacyBashInstallerCheck(),
            LegacyManifestCheck(),
            LegacyCLIWrapperCheck(),
            LegacyShellRCPathCheck(),
            SerenaMemoryMigrationCheck(),
        ]
    }
}

// MARK: - Serena memory migration

/// Detects .serena/memories/ files that should be migrated to .claude/memories/.
/// After migration, replaces the directory with a symlink so future Serena writes
/// land in .claude/memories/ automatically.
struct SerenaMemoryMigrationCheck: DoctorCheck, Sendable {
    let environment: Environment

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    var name: String { "Serena memories" }
    var section: String { "Migration" }

    func check() -> CheckResult {
        let serenaDir = environment.homeDirectory
            .appendingPathComponent(Constants.Serena.directory)
            .appendingPathComponent(Constants.Serena.memoriesDirectory)
        let fm = FileManager.default

        guard fm.fileExists(atPath: serenaDir.path) else {
            return .pass("no \(Constants.Serena.directory)/\(Constants.Serena.memoriesDirectory)/ found")
        }

        // Already a symlink → already migrated
        if let attrs = try? fm.attributesOfItem(atPath: serenaDir.path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            return .pass("\(Constants.Serena.directory)/\(Constants.Serena.memoriesDirectory)/ is a symlink (migrated)")
        }

        let contents = (try? fm.contentsOfDirectory(atPath: serenaDir.path)) ?? []

        if contents.isEmpty {
            return .fail(
                "\(Constants.Serena.directory)/\(Constants.Serena.memoriesDirectory)/ exists as directory — should be a symlink"
            )
        }

        return .fail(
            "\(Constants.Serena.directory)/\(Constants.Serena.memoriesDirectory)/ has \(contents.count) file(s) — migrate to \(Constants.FileNames.claudeDirectory)/\(Constants.Serena.memoriesDirectory)/"
        )
    }

    func fix() -> FixResult {
        let fm = FileManager.default
        let serenaDir = environment.homeDirectory
            .appendingPathComponent(Constants.Serena.directory)
            .appendingPathComponent(Constants.Serena.memoriesDirectory)
        let claudeDir = environment.memoriesDirectory

        let contents = (try? fm.contentsOfDirectory(atPath: serenaDir.path)) ?? []

        do {
            if !fm.fileExists(atPath: claudeDir.path) {
                try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            }

            var migrated = 0
            for file in contents {
                let src = serenaDir.appendingPathComponent(file)
                let dst = claudeDir.appendingPathComponent(file)
                if !fm.fileExists(atPath: dst.path) {
                    try fm.copyItem(at: src, to: dst)
                    migrated += 1
                }
            }

            // Replace real directory with symlink
            try fm.removeItem(at: serenaDir)
            try fm.createSymbolicLink(at: serenaDir, withDestinationURL: claudeDir)

            return .fixed("migrated \(migrated) file(s) and created symlink")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - Legacy bash installer cleanup

/// Detects ~/.claude-ios-setup/ (old repo clone) and offers to remove it.
struct LegacyBashInstallerCheck: DoctorCheck, Sendable {
    let environment: Environment

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    var name: String { "Legacy bash installer" }
    var section: String { "Migration" }

    func check() -> CheckResult {
        let legacyDir = environment.homeDirectory.appendingPathComponent(".claude-ios-setup")
        if FileManager.default.fileExists(atPath: legacyDir.path) {
            return .warn("~/.claude-ios-setup/ exists — old bash installer repo clone, safe to remove")
        }
        return .pass("no legacy installer directory")
    }

    func fix() -> FixResult {
        let legacyDir = environment.homeDirectory.appendingPathComponent(".claude-ios-setup")
        do {
            try FileManager.default.removeItem(at: legacyDir)
            return .fixed("removed ~/.claude-ios-setup/")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Detects old .setup-manifest that wasn't migrated to .mcs-manifest.
struct LegacyManifestCheck: DoctorCheck, Sendable {
    let environment: Environment

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    var name: String { "Legacy manifest file" }
    var section: String { "Migration" }

    func check() -> CheckResult {
        if FileManager.default.fileExists(atPath: environment.legacyManifest.path) {
            return .warn(".setup-manifest still exists — should be migrated to .mcs-manifest")
        }
        return .pass("no legacy manifest file")
    }

    func fix() -> FixResult {
        let fm = FileManager.default
        // If new manifest already exists, just remove the old one
        if fm.fileExists(atPath: environment.setupManifest.path) {
            do {
                try fm.removeItem(at: environment.legacyManifest)
                return .fixed("removed old .setup-manifest (already migrated)")
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        // Otherwise migrate
        if environment.migrateManifestIfNeeded() {
            return .fixed("migrated .setup-manifest → .mcs-manifest")
        }
        return .failed("could not migrate manifest")
    }
}

/// Detects old bash CLI wrapper at ~/.claude/bin/claude-ios-setup or on PATH.
struct LegacyCLIWrapperCheck: DoctorCheck, Sendable {
    let environment: Environment

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    var name: String { "Legacy CLI wrapper" }
    var section: String { "Migration" }

    func check() -> CheckResult {
        let fm = FileManager.default

        // Check the known wrapper location
        let binWrapper = environment.binDirectory.appendingPathComponent("claude-ios-setup")
        if fm.fileExists(atPath: binWrapper.path) {
            return .warn("~/.claude/bin/claude-ios-setup exists — old bash wrapper, safe to remove")
        }

        // Also check if it's on PATH somewhere else
        let shell = ShellRunner(environment: environment)
        let whichResult = shell.run("/usr/bin/which", arguments: ["claude-ios-setup"])
        if whichResult.succeeded, !whichResult.stdout.isEmpty {
            return .warn("legacy 'claude-ios-setup' found at \(whichResult.stdout) — safe to remove")
        }

        return .pass("no legacy CLI wrapper")
    }

    func fix() -> FixResult {
        let binWrapper = environment.binDirectory.appendingPathComponent("claude-ios-setup")
        if FileManager.default.fileExists(atPath: binWrapper.path) {
            do {
                try FileManager.default.removeItem(at: binWrapper)
                return .fixed("removed ~/.claude/bin/claude-ios-setup")
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return .notFixable("remove the legacy 'claude-ios-setup' from your PATH manually")
    }
}

/// Detects the old PATH entry added to .zshrc/.bash_profile by the bash installer.
/// The marker is: `# Added by Claude Code iOS Setup`
/// Checks all known RC files (not just the current shell) in case the user switched shells.
struct LegacyShellRCPathCheck: DoctorCheck, Sendable {
    let environment: Environment

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    var name: String { "Shell RC PATH entry" }
    var section: String { "Migration" }

    static let marker = "# Added by Claude Code iOS Setup"
    static let pathLine = "export PATH=\"$HOME/.claude/bin:$PATH\""

    /// All RC files that the old bash installer might have written to.
    static func allRCFiles(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".zshrc"),
            home.appendingPathComponent(".bash_profile"),
            home.appendingPathComponent(".bashrc"),
        ]
    }

    /// Returns RC files that contain the legacy marker.
    static func affectedFiles(home: URL) -> [URL] {
        allRCFiles(home: home).filter { file in
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return content.contains(marker)
        }
    }

    func check() -> CheckResult {
        let affected = Self.affectedFiles(home: environment.homeDirectory)

        if affected.isEmpty {
            return .pass("no legacy PATH entry")
        }

        let names = affected.map(\.lastPathComponent).joined(separator: ", ")
        return .warn(
            "\(names) has old PATH entry for ~/.claude/bin — no longer needed"
        )
    }

    func fix() -> FixResult {
        let affected = Self.affectedFiles(home: environment.homeDirectory)

        guard !affected.isEmpty else {
            return .notFixable("no affected RC files found")
        }

        var fixedFiles: [String] = []
        var errors: [String] = []

        for rcFile in affected {
            guard var content = try? String(contentsOf: rcFile, encoding: .utf8) else {
                errors.append("could not read \(rcFile.lastPathComponent)")
                continue
            }

            var lines = content.components(separatedBy: "\n")
            var removed = false

            lines.removeAll { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == Self.marker || trimmed == Self.pathLine {
                    removed = true
                    return true
                }
                return false
            }

            guard removed else { continue }

            // Clean up any resulting double blank lines
            content = lines.joined(separator: "\n")
            while content.contains("\n\n\n") {
                content = content.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            }

            do {
                var backup = Backup()
                try backup.backupFile(at: rcFile)
                try content.write(to: rcFile, atomically: true, encoding: .utf8)
                fixedFiles.append(rcFile.lastPathComponent)
            } catch {
                errors.append("\(rcFile.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !errors.isEmpty {
            return .failed(errors.joined(separator: "; "))
        }
        return .fixed("removed PATH entry from \(fixedFiles.joined(separator: ", "))")
    }
}

// MARK: - Manifest freshness (config drift)

/// Checks installed files against manifest hashes to detect drift.
struct ManifestFreshnessCheck: DoctorCheck, Sendable {
    var name: String { "Installed file integrity" }
    var section: String { "File Freshness" }

    func check() -> CheckResult {
        let env = Environment()
        let manifest = Manifest(path: env.setupManifest)
        let tracked = manifest.trackedPaths

        guard !tracked.isEmpty else {
            return .skip("no manifest found — run 'mcs install' first")
        }

        var drifted: [String] = []
        var missing: [String] = []

        for relativePath in tracked {
            let installedFile = env.claudeDirectory.appendingPathComponent(relativePath)
            let fm = FileManager.default

            guard fm.fileExists(atPath: installedFile.path) else {
                missing.append(relativePath)
                continue
            }

            if let matches = manifest.check(relativePath: relativePath, installedFile: installedFile),
               !matches {
                drifted.append(relativePath)
            }
        }

        if drifted.isEmpty && missing.isEmpty {
            return .pass("\(tracked.count) file(s) match manifest")
        }

        var issues: [String] = []
        if !drifted.isEmpty {
            issues.append("\(drifted.count) modified: \(drifted.joined(separator: ", "))")
        }
        if !missing.isEmpty {
            issues.append("\(missing.count) missing: \(missing.joined(separator: ", "))")
        }
        return .warn(issues.joined(separator: "; "))
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to restore files to expected state")
    }
}
