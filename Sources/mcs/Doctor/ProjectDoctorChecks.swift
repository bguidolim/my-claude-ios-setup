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

/// Checks for <project>/.serena/memories/ that should be migrated.
struct ProjectSerenaMemoryCheck: DoctorCheck, Sendable {
    let projectRoot: URL

    var name: String { "Project Serena memories" }
    var section: String { "Project" }

    func check() -> CheckResult {
        let serenaDir = projectRoot
            .appendingPathComponent(".serena")
            .appendingPathComponent("memories")
        let fm = FileManager.default

        guard fm.fileExists(atPath: serenaDir.path) else {
            return .pass("no .serena/memories/ found")
        }
        let contents: [String]
        do {
            contents = try fm.contentsOfDirectory(atPath: serenaDir.path)
        } catch {
            return .warn(".serena/memories/ exists but could not be read: \(error.localizedDescription)")
        }
        guard !contents.isEmpty else {
            return .pass(".serena/memories/ exists but is empty")
        }
        return .warn(".serena/memories/ has \(contents.count) file(s) — migrate to .claude/memories/")
    }

    func fix() -> FixResult {
        let fm = FileManager.default
        let serenaDir = projectRoot
            .appendingPathComponent(".serena")
            .appendingPathComponent("memories")
        let claudeDir = projectRoot
            .appendingPathComponent(Constants.FileNames.claudeDirectory)
            .appendingPathComponent("memories")

        do {
            if !fm.fileExists(atPath: claudeDir.path) {
                try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            }

            let files = try fm.contentsOfDirectory(
                at: serenaDir, includingPropertiesForKeys: nil
            )
            var migrated = 0
            for file in files {
                let dest = claudeDir.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try fm.copyItem(at: file, to: dest)
                    migrated += 1
                }
            }
            return .fixed("migrated \(migrated) file(s) to .claude/memories/")
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
