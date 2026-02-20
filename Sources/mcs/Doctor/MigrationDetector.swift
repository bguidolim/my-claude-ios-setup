import Foundation

/// Doctor checks that detect migration needs from older installations.
enum MigrationDetector {
    static var checks: [any DoctorCheck] {
        [
            SerenaMemoryMigrationCheck(),
            DeprecatedUvCheck(),
            CLIWrapperMigrationCheck(),
        ]
    }
}

// MARK: - Serena memory migration

/// Detects .serena/memories/ files that should be migrated to .claude/memories/.
struct SerenaMemoryMigrationCheck: DoctorCheck, Sendable {
    var name: String { "Serena memories" }
    var section: String { "Migration" }

    func check() -> CheckResult {
        let env = Environment()
        let serenaDir = env.homeDirectory.appendingPathComponent(".serena/memories")
        let fm = FileManager.default

        guard fm.fileExists(atPath: serenaDir.path) else {
            return .pass("no .serena/memories/ found (good)")
        }

        guard let contents = try? fm.contentsOfDirectory(atPath: serenaDir.path),
              !contents.isEmpty
        else {
            return .pass("no .serena/memories/ found (good)")
        }

        return .warn(
            ".serena/memories/ has \(contents.count) file(s) — migrate to .claude/memories/"
        )
    }

    func fix() -> FixResult {
        let env = Environment()
        let fm = FileManager.default
        let serenaDir = env.homeDirectory.appendingPathComponent(".serena/memories")
        let claudeDir = env.memoriesDirectory

        guard let contents = try? fm.contentsOfDirectory(atPath: serenaDir.path),
              !contents.isEmpty
        else {
            return .fixed("nothing to migrate")
        }

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
            return .fixed("migrated \(migrated) file(s) to .claude/memories/")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - Deprecated uv dependency

/// Detects if uv is installed (no longer needed after Serena removal).
struct DeprecatedUvCheck: DoctorCheck, Sendable {
    var name: String { "uv (deprecated)" }
    var section: String { "Migration" }

    func check() -> CheckResult {
        let shell = ShellRunner(environment: Environment())
        if shell.commandExists("uv") {
            return .warn("'uv' is still installed — no longer needed (was a Serena dependency)")
        }
        return .pass("not present (good)")
    }

    func fix() -> FixResult {
        let env = Environment()
        let shell = ShellRunner(environment: env)
        let brew = Homebrew(shell: shell, environment: env)

        if brew.isPackageInstalled("uv") {
            let result = shell.run(env.brewPath, arguments: ["uninstall", "uv"])
            if result.succeeded {
                return .fixed("uninstalled uv via Homebrew")
            }
            return .failed(result.stderr)
        }
        return .notFixable("uv was not installed via Homebrew — remove it manually")
    }
}

// MARK: - CLI wrapper migration

/// Detects old bash CLI wrapper that should be replaced with the Swift binary.
struct CLIWrapperMigrationCheck: DoctorCheck, Sendable {
    var name: String { "CLI wrapper" }
    var section: String { "Migration" }

    func check() -> CheckResult {
        let shell = ShellRunner(environment: Environment())
        let whichResult = shell.run("/usr/bin/which", arguments: ["claude-ios-setup"])

        guard whichResult.succeeded, !whichResult.stdout.isEmpty else {
            // Old CLI not on PATH — no migration needed
            return .pass("no legacy CLI wrapper found")
        }

        let path = whichResult.stdout
        // Check if it's a shell script (old bash version) vs compiled binary
        let fileResult = shell.run("/usr/bin/file", arguments: [path])
        if fileResult.stdout.contains("shell script") || fileResult.stdout.contains("text") {
            return .warn(
                "legacy bash CLI wrapper at \(path) — replace with 'brew install mcs' or remove it"
            )
        }
        return .pass("CLI wrapper is not a legacy script")
    }

    func fix() -> FixResult {
        .notFixable("Remove the old bash wrapper manually, then install via: brew install mcs")
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
