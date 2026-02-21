import Foundation

/// Shared project configuration logic used by both ConfigureCommand and Installer.
/// Handles template generation, CLAUDE.local.md writing, memory migration,
/// gitignore updates, and pack-specific configuration.
struct ProjectConfigurator {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner

    /// Full interactive configure flow — shows header, pack selection,
    /// runs configure, and shows completion.
    /// Used by both `mcs configure` (no --pack) and post-install inline configure.
    func interactiveConfigure(at projectPath: URL) throws {
        output.header("Configure Project")
        output.plain("")
        output.warn("This command should be run inside your project directory.")
        output.info("Project: \(projectPath.path)")

        let registry = TechPackRegistry.shared
        let packs = registry.availablePacks
        guard !packs.isEmpty else {
            output.error("No tech packs available.")
            return
        }

        let items = packs.map { (name: $0.displayName, description: $0.description) }
        let selected = output.singleSelect(title: "Select a tech pack:", items: items)
        let selectedPack = packs[selected]

        output.info("Tech pack: \(selectedPack.displayName)")

        try configure(at: projectPath, pack: selectedPack)

        output.header("Done")
        output.info("Run 'mcs doctor' to verify configuration")
    }

    /// Configure a project at the given path with the specified pack.
    func configure(
        at projectPath: URL,
        pack: any TechPack
    ) throws {
        // Auto-install missing pack components
        var packInstaller = PackInstaller(
            environment: environment,
            output: output,
            shell: shell
        )
        packInstaller.installPack(pack)

        // Get repo name
        let repoName: String
        let gitResult = shell.run(
            "/usr/bin/git",
            arguments: ["-C", projectPath.path, "rev-parse", "--show-toplevel"]
        )
        if gitResult.succeeded, !gitResult.stdout.isEmpty {
            repoName = URL(fileURLWithPath: gitResult.stdout).lastPathComponent
        } else {
            repoName = projectPath.lastPathComponent
        }

        // Gather all template contributions
        let allContributions = gatherTemplateContributions(
            projectPath: projectPath,
            pack: pack
        )

        // Only create/update CLAUDE.local.md if there's content to add
        if !allContributions.isEmpty {
            let values: [String: String] = ["REPO_NAME": repoName]
            try writeClaudeLocal(
                at: projectPath,
                contributions: allContributions,
                values: values
            )
        } else {
            output.info("No template sections to add — skipping CLAUDE.local.md")
        }

        // Memory migration from Serena
        migrateSerenaMemories(at: projectPath)

        // Add .claude entries to project .gitignore
        try updateProjectGitignore(at: projectPath)

        // Run pack-specific configuration
        let context = ProjectConfigContext(
            projectPath: projectPath,
            repoName: repoName
        )
        try pack.configureProject(at: projectPath, context: context)
        output.success("Applied \(pack.displayName) configuration")

        // Write per-project state file
        var projectState = ProjectState(projectRoot: projectPath)
        projectState.recordPack(pack.identifier)
        do {
            try projectState.save()
            output.success("Updated .claude/.mcs-project")
        } catch {
            output.warn("Could not write .mcs-project: \(error.localizedDescription)")
        }
    }

    // MARK: - Template Gathering

    /// Collect all template contributions from CoreTechPack, symlink detection, and the selected pack.
    private func gatherTemplateContributions(
        projectPath: URL,
        pack: any TechPack
    ) -> [TemplateContribution] {
        var contributions: [TemplateContribution] = []

        // Symlink detection — project-specific, cannot be in TechPack.templates
        let claudeMD = projectPath.appendingPathComponent("CLAUDE.md")
        let fm = FileManager.default
        if fm.fileExists(atPath: claudeMD.path),
           (try? fm.destinationOfSymbolicLink(atPath: claudeMD.path)) != nil {
            contributions.append(TemplateContribution(
                sectionIdentifier: "core",
                templateContent: CoreTemplates.symlinkNote,
                placeholders: []
            ))
        }

        // Core conditional sections (continuous learning KB search)
        let corePack = CoreTechPack()
        contributions.append(contentsOf: corePack.templates)

        // Selected pack sections (e.g., iOS) — skip if Core is the selected pack
        // since we already gathered its templates above.
        if pack.identifier != corePack.identifier {
            contributions.append(contentsOf: pack.templates)
        }

        return contributions
    }

    // MARK: - CLAUDE.local.md Writing

    /// Compose and write CLAUDE.local.md from template contributions.
    private func writeClaudeLocal(
        at projectPath: URL,
        contributions: [TemplateContribution],
        values: [String: String]
    ) throws {
        let version = MCSVersion.current
        let claudeLocalPath = projectPath.appendingPathComponent(Constants.FileNames.claudeLocalMD)
        let fm = FileManager.default

        // Separate core section from other sections
        let coreContribution = contributions.first { $0.sectionIdentifier == "core" }
        let otherContributions = contributions.filter { $0.sectionIdentifier != "core" }

        let coreContent = coreContribution?.templateContent ?? ""

        let composed: String
        if fm.fileExists(atPath: claudeLocalPath.path) {
            let existingContent = try String(contentsOf: claudeLocalPath, encoding: .utf8)
            let userContent = TemplateComposer.extractUserContent(from: existingContent)

            // Update core section
            let processedCore = TemplateEngine.substitute(template: coreContent, values: values)
            var updated = TemplateComposer.replaceSection(
                in: existingContent,
                sectionIdentifier: "core",
                newContent: processedCore,
                newVersion: version
            )

            // Update other sections
            for contribution in otherContributions {
                let processedContent = TemplateEngine.substitute(
                    template: contribution.templateContent,
                    values: values
                )
                updated = TemplateComposer.replaceSection(
                    in: updated,
                    sectionIdentifier: contribution.sectionIdentifier,
                    newContent: processedContent,
                    newVersion: version
                )
            }

            // Preserve user content that was outside markers
            let trimmedUser = userContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedUser.isEmpty {
                let currentUser = TemplateComposer.extractUserContent(from: updated)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if currentUser.isEmpty {
                    updated += "\n\n" + trimmedUser + "\n"
                }
            }

            composed = updated
        } else {
            composed = TemplateComposer.compose(
                coreContent: coreContent,
                packContributions: otherContributions,
                values: values
            )
        }

        // Write with backup
        var backup = Backup()
        if fm.fileExists(atPath: claudeLocalPath.path) {
            do {
                try backup.backupFile(at: claudeLocalPath)
            } catch {
                output.warn("Could not create backup: \(error.localizedDescription)")
            }
        }
        try composed.write(to: claudeLocalPath, atomically: true, encoding: .utf8)
        output.success("Generated CLAUDE.local.md")
    }

    // MARK: - Memory Migration

    private func migrateSerenaMemories(at projectPath: URL) {
        let fm = FileManager.default
        let serenaMemories = projectPath.appendingPathComponent(".serena")
            .appendingPathComponent("memories")
        let newMemories = projectPath.appendingPathComponent(Constants.FileNames.claudeDirectory)
            .appendingPathComponent("memories")

        guard fm.fileExists(atPath: serenaMemories.path) else { return }

        output.info("Found .serena/memories/ -- migrating to .claude/memories/")

        do {
            if !fm.fileExists(atPath: newMemories.path) {
                try fm.createDirectory(at: newMemories, withIntermediateDirectories: true)
            }

            let memoryFiles = try fm.contentsOfDirectory(
                at: serenaMemories,
                includingPropertiesForKeys: nil
            )

            var migrated = 0
            for file in memoryFiles {
                let destFile = newMemories.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: destFile.path) {
                    try fm.copyItem(at: file, to: destFile)
                    migrated += 1
                }
            }

            output.success("Migrated \(migrated) memory file(s) to .claude/memories/")
            output.info("Original files preserved in .serena/memories/ -- delete manually after verification")
        } catch {
            output.warn("Memory migration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Gitignore

    private func updateProjectGitignore(at projectPath: URL) throws {
        let fm = FileManager.default
        let projectGitignore = projectPath.appendingPathComponent(".gitignore")

        guard fm.fileExists(atPath: projectGitignore.path) else { return }

        var content = try String(contentsOf: projectGitignore, encoding: .utf8)
        var added: [String] = []
        for entry in ["\(Constants.FileNames.claudeDirectory)/memories/", "\(Constants.FileNames.claudeDirectory)/\(Constants.FileNames.mcsProject)"] {
            if !content.contains(entry) {
                if !content.hasSuffix("\n") { content += "\n" }
                content += "\(entry)\n"
                added.append(entry)
            }
        }
        if !added.isEmpty {
            try content.write(to: projectGitignore, atomically: true, encoding: .utf8)
            output.success("Added \(added.joined(separator: ", ")) to project .gitignore")
        }
    }
}
