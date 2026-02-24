import Foundation

/// Context passed to project-scoped doctor checks.
struct ProjectDoctorContext: Sendable {
    let projectRoot: URL
    let registry: TechPackRegistry
}

/// Doctor checks that only run when inside a detected project root.
enum ProjectDoctorChecks {
    static func checks(context: ProjectDoctorContext) -> [any DoctorCheck] {
        [
            CLAUDELocalFreshnessCheck(context: context),
            ProjectSerenaMemoryCheck(projectRoot: context.projectRoot),
            ProjectStateFileCheck(projectRoot: context.projectRoot),
        ]
    }
}

// MARK: - CLAUDE.local.md freshness check

/// Verifies CLAUDE.local.md sections via content-hash comparison (when stored values exist)
/// or version-only comparison (legacy fallback).
struct CLAUDELocalFreshnessCheck: DoctorCheck, Sendable {
    let context: ProjectDoctorContext

    var name: String { "CLAUDE.local.md freshness" }
    var section: String { "Project" }

    func check() -> CheckResult {
        let claudeLocal = context.projectRoot.appendingPathComponent(Constants.FileNames.claudeLocalMD)
        guard FileManager.default.fileExists(atPath: claudeLocal.path) else {
            return .skip("CLAUDE.local.md not found")
        }
        let content: String
        do {
            content = try String(contentsOf: claudeLocal, encoding: .utf8)
        } catch {
            return .fail("CLAUDE.local.md exists but could not be read: \(error.localizedDescription)")
        }

        let sections = TemplateComposer.parseSections(from: content)
        guard !sections.isEmpty else {
            return .warn("CLAUDE.local.md has no mcs section markers — run 'mcs sync'")
        }

        let state: ProjectState
        do {
            state = try ProjectState(projectRoot: context.projectRoot)
        } catch {
            return .warn("could not read .mcs-project: \(error.localizedDescription) — run 'mcs sync' to regenerate")
        }

        // If we have stored resolved values, use content-hash comparison
        if let storedValues = state.resolvedValues {
            let (expectedSections, buildErrors) = buildExpectedSections(state: state, values: storedValues)

            if !buildErrors.isEmpty {
                return .warn("could not fully verify: \(buildErrors.joined(separator: "; "))")
            }

            let result = SectionValidator.validate(fileURL: claudeLocal, expectedSections: expectedSections)

            if result.sections.isEmpty && !expectedSections.isEmpty {
                return .fail("could not validate sections — file may have changed during check")
            }

            if result.hasOutdated {
                let outdated = result.outdatedSections.map { "\($0.identifier) (\($0.detail))" }
                return .fail("outdated sections: \(outdated.joined(separator: ", ")) — run 'mcs sync' or 'mcs doctor --fix'")
            }
            return .pass("all sections up to date (content verified)")
        }

        // Legacy fallback: version-only check
        let currentVersion = MCSVersion.current
        var outdated: [String] = []
        for section in sections {
            if section.version != currentVersion {
                outdated.append("\(section.identifier) (v\(section.version))")
            }
        }

        if outdated.isEmpty {
            return .pass("all sections at v\(currentVersion) (version-only)")
        }
        return .warn("outdated sections: \(outdated.joined(separator: ", ")) — run 'mcs sync' (version-only)")
    }

    func fix() -> FixResult {
        let state: ProjectState
        do {
            state = try ProjectState(projectRoot: context.projectRoot)
        } catch {
            return .failed("could not read .mcs-project: \(error.localizedDescription)")
        }

        guard let storedValues = state.resolvedValues else {
            return .notFixable("Run 'mcs sync' to update CLAUDE.local.md (no stored values for auto-fix)")
        }

        let claudeLocal = context.projectRoot.appendingPathComponent(Constants.FileNames.claudeLocalMD)
        let (expectedSections, buildErrors) = buildExpectedSections(state: state, values: storedValues)

        if !buildErrors.isEmpty {
            return .failed("could not build expected sections: \(buildErrors.joined(separator: "; "))")
        }

        do {
            let updated = try SectionValidator.fix(fileURL: claudeLocal, expectedSections: expectedSections)
            if updated {
                return .fixed("re-rendered outdated sections from stored values")
            }
            // Verify the file is readable — SectionValidator.fix returns false both when
            // nothing needs fixing AND when it can't read the file
            guard FileManager.default.isReadableFile(atPath: claudeLocal.path) else {
                return .failed("CLAUDE.local.md became unreadable during fix")
            }
            return .fixed("no changes needed")
        } catch {
            return .failed("could not fix CLAUDE.local.md: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Build expected sections by re-rendering current pack templates with stored values.
    /// Returns both the expected sections and any errors encountered during template loading.
    private func buildExpectedSections(
        state: ProjectState,
        values: [String: String]
    ) -> (sections: [String: (version: String, content: String)], errors: [String]) {
        var expected: [String: (version: String, content: String)] = [:]
        var errors: [String] = []

        for packID in state.configuredPacks {
            guard let pack = context.registry.pack(for: packID) else { continue }
            let templates: [TemplateContribution]
            do {
                templates = try pack.templates
            } catch {
                errors.append("\(packID): failed to load templates — \(error.localizedDescription)")
                continue
            }
            for contribution in templates {
                let rendered = TemplateEngine.substitute(
                    template: contribution.templateContent,
                    values: values
                )
                expected[contribution.sectionIdentifier] = (
                    version: MCSVersion.current,
                    content: rendered
                )
            }
        }

        return (expected, errors)
    }
}

// MARK: - Project-local Serena memory migration

/// Checks for <project>/.serena/memories/ that should be migrated to .claude/memories/
/// and replaced with a symlink.
struct ProjectSerenaMemoryCheck: DoctorCheck, Sendable {
    let projectRoot: URL

    var name: String { "Project Serena memories" }
    var section: String { "Project" }

    func check() -> CheckResult {
        let serenaDir = projectRoot
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

        let contents: [String]
        do {
            contents = try fm.contentsOfDirectory(atPath: serenaDir.path)
        } catch {
            return .fail("\(Constants.Serena.directory)/\(Constants.Serena.memoriesDirectory)/ exists but could not be read")
        }
        guard !contents.isEmpty else {
            return .fail("\(Constants.Serena.directory)/\(Constants.Serena.memoriesDirectory)/ exists as directory — should be a symlink")
        }
        return .fail("\(Constants.Serena.directory)/\(Constants.Serena.memoriesDirectory)/ has \(contents.count) file(s) — migrate to \(Constants.FileNames.claudeDirectory)/\(Constants.Serena.memoriesDirectory)/")
    }

    func fix() -> FixResult {
        let fm = FileManager.default
        let serenaDir = projectRoot
            .appendingPathComponent(Constants.Serena.directory)
            .appendingPathComponent(Constants.Serena.memoriesDirectory)
        let claudeDir = projectRoot
            .appendingPathComponent(Constants.FileNames.claudeDirectory)
            .appendingPathComponent(Constants.Serena.memoriesDirectory)

        do {
            if !fm.fileExists(atPath: claudeDir.path) {
                try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            }

            // List source files — fail hard if listing fails
            let sourceFiles = try fm.contentsOfDirectory(at: serenaDir, includingPropertiesForKeys: nil)

            // Copy all files
            for file in sourceFiles {
                let dest = claudeDir.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try fm.copyItem(at: file, to: dest)
                }
            }

            // Verify all source files exist at destination before deleting source
            for file in sourceFiles {
                let dest = claudeDir.appendingPathComponent(file.lastPathComponent)
                guard fm.fileExists(atPath: dest.path) else {
                    return .failed("\(file.lastPathComponent) not found at destination after copy")
                }
            }

            // Replace directory with symlink
            try fm.removeItem(at: serenaDir)
            try fm.createSymbolicLink(at: serenaDir, withDestinationURL: claudeDir)

            return .fixed("migrated \(sourceFiles.count) file(s) and created symlink")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - Project state file check

/// Warns if CLAUDE.local.md exists but .mcs-project doesn't.
/// Fix: infers packs from section markers and creates the file.
struct ProjectStateFileCheck: DoctorCheck, Sendable {
    let projectRoot: URL

    var name: String { "Project state file" }
    var section: String { "Project" }

    func check() -> CheckResult {
        let claudeLocal = projectRoot.appendingPathComponent(Constants.FileNames.claudeLocalMD)

        guard FileManager.default.fileExists(atPath: claudeLocal.path) else {
            return .skip("no CLAUDE.local.md — run 'mcs sync'")
        }

        do {
            let state = try ProjectState(projectRoot: projectRoot)
            if state.exists {
                return .pass(".mcs-project present")
            }
        } catch {
            return .warn("corrupt .mcs-project: \(error.localizedDescription) — run 'mcs doctor --fix'")
        }
        return .warn("CLAUDE.local.md exists but .mcs-project missing — run 'mcs doctor --fix'")
    }

    func fix() -> FixResult {
        let claudeLocal = projectRoot.appendingPathComponent(Constants.FileNames.claudeLocalMD)
        let content: String
        do {
            content = try String(contentsOf: claudeLocal, encoding: .utf8)
        } catch {
            return .failed("could not read CLAUDE.local.md: \(error.localizedDescription)")
        }

        // Infer packs from section markers
        let sections = TemplateComposer.parseSections(from: content)
        let packIdentifiers = sections
            .map(\.identifier)
            .filter { $0 != "core" }

        // Delete corrupt state file if present so we can rebuild cleanly
        let stateFile = projectRoot
            .appendingPathComponent(Constants.FileNames.claudeDirectory)
            .appendingPathComponent(Constants.FileNames.mcsProject)
        if FileManager.default.fileExists(atPath: stateFile.path) {
            do {
                try FileManager.default.removeItem(at: stateFile)
            } catch {
                return .failed("could not delete corrupt .mcs-project: \(error.localizedDescription) — remove it manually and re-run")
            }
        }

        // After deletion, init cannot throw (file no longer exists), so build and save in one block
        do {
            var state = try ProjectState(projectRoot: projectRoot)
            for pack in packIdentifiers {
                state.recordPack(pack)
            }
            try state.save()
            return .fixed("created .mcs-project with packs: \(packIdentifiers.joined(separator: ", "))")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
