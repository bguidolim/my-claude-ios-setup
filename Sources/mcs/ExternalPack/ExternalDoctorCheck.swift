import Foundation

// MARK: - Misconfigured Check

/// A diagnostic check returned when a doctor check definition has missing required fields.
/// Always reports a warning so the user knows the pack manifest is misconfigured.
struct MisconfiguredDoctorCheck: DoctorCheck, Sendable {
    let name: String
    let section: String
    let reason: String

    func check() -> CheckResult {
        .warn("misconfigured: \(reason)")
    }

    func fix() -> FixResult {
        .notFixable("Fix the pack's techpack.yaml: \(reason)")
    }
}

// MARK: - Command Exists Check

/// Checks that a command is available. First attempts to run with the given arguments;
/// if that fails, falls back to checking PATH presence.
struct ExternalCommandExistsCheck: DoctorCheck, Sendable {
    let name: String
    let section: String
    let command: String
    let args: [String]
    let fixCommand: String?
    let scriptRunner: ScriptRunner?

    func check() -> CheckResult {
        let shell = ShellRunner(environment: Environment())
        let result = shell.run(command, arguments: args)
        if result.succeeded {
            return .pass("available")
        }
        // Also try as a command name on PATH (not a full path)
        if shell.commandExists(command) {
            return .pass("installed")
        }
        return .fail("not found")
    }

    func fix() -> FixResult {
        guard let fixCommand else {
            return .notFixable("Run 'mcs install' to install dependencies")
        }
        if let scriptRunner {
            let result = scriptRunner.runCommand(fixCommand)
            if result.succeeded {
                return .fixed("fix command succeeded")
            }
            return .failed(result.stderr)
        }
        // Fallback when no script runner is injected (uses ShellRunner directly)
        let shell = ShellRunner(environment: Environment())
        let result = shell.shell(fixCommand)
        if result.succeeded {
            return .fixed("fix command succeeded")
        }
        return .failed(result.stderr)
    }
}

// MARK: - File Exists Check

/// Checks that a file exists at the given path.
struct ExternalFileExistsCheck: ScopedPathCheck, Sendable {
    let name: String
    let section: String
    let path: String
    let scope: ExternalDoctorCheckScope
    let projectRoot: URL?

    func check() -> CheckResult {
        guard let resolved = resolvePath() else {
            return .skip("no project root for project-scoped check")
        }
        if FileManager.default.fileExists(atPath: resolved) {
            return .pass("present")
        }
        return .fail("missing")
    }
}

// MARK: - Directory Exists Check

/// Checks that a directory exists at the given path.
struct ExternalDirectoryExistsCheck: ScopedPathCheck, Sendable {
    let name: String
    let section: String
    let path: String
    let scope: ExternalDoctorCheckScope
    let projectRoot: URL?

    func check() -> CheckResult {
        guard let resolved = resolvePath() else {
            return .skip("no project root for project-scoped check")
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue {
            return .pass("present")
        }
        return .fail("missing")
    }
}

// MARK: - File Contains Check

/// Checks that a file contains a given substring.
struct ExternalFileContainsCheck: ScopedPathCheck, Sendable {
    let name: String
    let section: String
    let path: String
    let pattern: String
    let scope: ExternalDoctorCheckScope
    let projectRoot: URL?

    func check() -> CheckResult {
        guard let resolved = resolvePath() else {
            return .skip("no project root for project-scoped check")
        }
        guard let content = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            return .fail("file not found or unreadable")
        }
        if content.contains(pattern) {
            return .pass("pattern found")
        }
        return .fail("pattern not found")
    }
}

// MARK: - File Not Contains Check

/// Checks that a file does NOT contain a given substring.
struct ExternalFileNotContainsCheck: ScopedPathCheck, Sendable {
    let name: String
    let section: String
    let path: String
    let pattern: String
    let scope: ExternalDoctorCheckScope
    let projectRoot: URL?

    func check() -> CheckResult {
        guard let resolved = resolvePath() else {
            return .skip("no project root for project-scoped check")
        }
        guard let content = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            // File not found — pattern is not present, so this passes
            return .pass("file not present (pattern absent)")
        }
        if content.contains(pattern) {
            return .fail("unwanted pattern found")
        }
        return .pass("pattern absent")
    }
}

// MARK: - Shell Script Check

/// Runs a custom shell script with exit code conventions:
/// - 0 = pass
/// - 1 = fail
/// - 2 = warn
/// - 3 = skip
/// stdout is used as the message.
struct ExternalShellScriptCheck: DoctorCheck, Sendable {
    let name: String
    let section: String
    let scriptPath: URL
    let packPath: URL
    let fixScriptPath: URL?
    let fixCommand: String?
    let scriptRunner: ScriptRunner

    func check() -> CheckResult {
        let result: ScriptRunner.ScriptResult
        do {
            result = try scriptRunner.run(script: scriptPath, packPath: packPath)
        } catch {
            return .fail(error.localizedDescription)
        }

        let message = result.stdout.isEmpty ? name : result.stdout

        switch result.exitCode {
        case 0:
            return .pass(message)
        case 1:
            return .fail(message)
        case 2:
            return .warn(message)
        case 3:
            return .skip(message)
        default:
            return .fail("unexpected exit code \(result.exitCode): \(message)")
        }
    }

    func fix() -> FixResult {
        if let fixScriptPath {
            do {
                let result = try scriptRunner.run(script: fixScriptPath, packPath: packPath)
                if result.succeeded {
                    let message = result.stdout.isEmpty ? "fix applied" : result.stdout
                    return .fixed(message)
                }
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                return .failed(message.isEmpty ? "fix script failed" : message)
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        if let fixCommand {
            let result = scriptRunner.runCommand(fixCommand)
            if result.succeeded {
                let message = result.stdout.isEmpty ? "fix applied" : result.stdout
                return .fixed(message)
            }
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            return .failed(message.isEmpty ? "fix command failed" : message)
        }

        return .notFixable("No fix available for this check")
    }
}

// MARK: - Factory

/// Creates concrete `DoctorCheck` instances from declarative `ExternalDoctorCheckDefinition`.
/// Definitions are expected to be pre-validated by `ExternalPackManifest.validate()`.
enum ExternalDoctorCheckFactory {
    /// Build a `DoctorCheck` from a declarative definition.
    ///
    /// - Parameters:
    ///   - definition: The declarative check from the manifest (must be pre-validated)
    ///   - packPath: Root directory of the external pack
    ///   - projectRoot: Project root for project-scoped checks (nil if not in a project)
    ///   - scriptRunner: Runner for shell script checks
    static func makeCheck(
        from definition: ExternalDoctorCheckDefinition,
        packPath: URL,
        projectRoot: URL?,
        scriptRunner: ScriptRunner
    ) -> any DoctorCheck {
        let section = definition.section ?? "External Pack"
        let scope = definition.scope ?? .global

        switch definition.type {
        case .commandExists:
            guard let command = definition.command, !command.isEmpty else {
                return MisconfiguredDoctorCheck(
                    name: definition.name, section: section,
                    reason: "commandExists requires non-empty 'command'"
                )
            }
            return ExternalCommandExistsCheck(
                name: definition.name,
                section: section,
                command: command,
                args: definition.args ?? [],
                fixCommand: definition.fixCommand,
                scriptRunner: scriptRunner
            )

        case .fileExists:
            guard let path = definition.path, !path.isEmpty else {
                return MisconfiguredDoctorCheck(
                    name: definition.name, section: section,
                    reason: "fileExists requires non-empty 'path'"
                )
            }
            return ExternalFileExistsCheck(
                name: definition.name,
                section: section,
                path: path,
                scope: scope,
                projectRoot: projectRoot
            )

        case .directoryExists:
            guard let path = definition.path, !path.isEmpty else {
                return MisconfiguredDoctorCheck(
                    name: definition.name, section: section,
                    reason: "directoryExists requires non-empty 'path'"
                )
            }
            return ExternalDirectoryExistsCheck(
                name: definition.name,
                section: section,
                path: path,
                scope: scope,
                projectRoot: projectRoot
            )

        case .fileContains:
            guard let path = definition.path, !path.isEmpty,
                  let pattern = definition.pattern, !pattern.isEmpty else {
                return MisconfiguredDoctorCheck(
                    name: definition.name, section: section,
                    reason: "fileContains requires non-empty 'path' and 'pattern'"
                )
            }
            return ExternalFileContainsCheck(
                name: definition.name,
                section: section,
                path: path,
                pattern: pattern,
                scope: scope,
                projectRoot: projectRoot
            )

        case .fileNotContains:
            guard let path = definition.path, !path.isEmpty,
                  let pattern = definition.pattern, !pattern.isEmpty else {
                return MisconfiguredDoctorCheck(
                    name: definition.name, section: section,
                    reason: "fileNotContains requires non-empty 'path' and 'pattern'"
                )
            }
            return ExternalFileNotContainsCheck(
                name: definition.name,
                section: section,
                path: path,
                pattern: pattern,
                scope: scope,
                projectRoot: projectRoot
            )

        case .shellScript:
            // command is guaranteed non-empty by manifest validation
            let scriptURL = packPath.appendingPathComponent(definition.command ?? "")
            let fixURL: URL? = definition.fixScript.map {
                packPath.appendingPathComponent($0)
            }
            return ExternalShellScriptCheck(
                name: definition.name,
                section: section,
                scriptPath: scriptURL,
                packPath: packPath,
                fixScriptPath: fixURL,
                fixCommand: definition.fixCommand,
                scriptRunner: scriptRunner
            )
        }
    }
}

// MARK: - Scoped Path Protocol

/// Shared path resolution for doctor checks that operate on a file or directory
/// with global or project scope.
protocol ScopedPathCheck: DoctorCheck {
    var path: String { get }
    var scope: ExternalDoctorCheckScope { get }
    var projectRoot: URL? { get }
}

extension ScopedPathCheck {
    func resolvePath() -> String? {
        switch scope {
        case .global:
            return expandTilde(path)
        case .project:
            guard let root = projectRoot else { return nil }
            let resolved = root.appendingPathComponent(path).resolvingSymlinksInPath().path
            let rootBase = root.resolvingSymlinksInPath().path
            let rootPrefix = rootBase.hasSuffix("/") ? rootBase : rootBase + "/"
            // Ensure the resolved path stays within the project root
            guard resolved.hasPrefix(rootPrefix) || resolved == rootBase else {
                return nil
            }
            return resolved
        }
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs install' to install")
    }
}

// MARK: - Helpers

/// Expand `~` at the start of a path to the user's home directory.
func expandTilde(_ path: String) -> String {
    if path.hasPrefix("~/") {
        return NSString(string: path).expandingTildeInPath
    }
    return path
}
