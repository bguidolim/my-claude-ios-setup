import Foundation

/// Doctor checks that only run when inside a detected project root.
enum ProjectDoctorChecks {
    static func checks(projectRoot: URL) -> [any DoctorCheck] {
        [
            CLAUDELocalVersionCheck(projectRoot: projectRoot),
            ProjectSerenaMemoryCheck(projectRoot: projectRoot),
            ProjectStateFileCheck(projectRoot: projectRoot),
        ]
    }
}

// MARK: - CLAUDE.local.md version check

/// Verifies that section markers in CLAUDE.local.md have the current MCS version.
struct CLAUDELocalVersionCheck: DoctorCheck, Sendable {
    let projectRoot: URL

    var name: String { "CLAUDE.local.md version" }
    var section: String { "Project" }

    func check() -> CheckResult {
        let claudeLocal = projectRoot.appendingPathComponent(Constants.FileNames.claudeLocalMD)
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
            return .warn("CLAUDE.local.md has no mcs section markers — run 'mcs configure'")
        }

        let currentVersion = MCSVersion.current
        var outdated: [String] = []
        for section in sections {
            if section.version != currentVersion {
                outdated.append("\(section.identifier) (v\(section.version))")
            }
        }

        if outdated.isEmpty {
            return .pass("all sections at v\(currentVersion)")
        }
        return .warn("outdated sections: \(outdated.joined(separator: ", ")) — run 'mcs configure'")
    }

    func fix() -> FixResult {
        .notFixable("Run 'mcs configure' to update CLAUDE.local.md")
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
        let state = ProjectState(projectRoot: projectRoot)

        guard FileManager.default.fileExists(atPath: claudeLocal.path) else {
            return .skip("no CLAUDE.local.md — run 'mcs configure'")
        }

        if state.exists {
            return .pass(".mcs-project present")
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

        var state = ProjectState(projectRoot: projectRoot)
        for pack in packIdentifiers {
            state.recordPack(pack)
        }

        do {
            try state.save()
            return .fixed("created .mcs-project with packs: \(packIdentifiers.joined(separator: ", "))")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
