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

        // Build initial context for template value resolution
        var context = ProjectConfigContext(
            projectPath: projectPath,
            repoName: repoName,
            output: output
        )

        // Resolve pack-specific template values (may prompt user, e.g. Xcode project selection)
        let packValues = pack.templateValues(context: context)

        // Rebuild context with resolved values so configureProject can access them
        context = ProjectConfigContext(
            projectPath: projectPath,
            repoName: repoName,
            output: output,
            resolvedValues: packValues
        )

        // Gather all template contributions
        let allContributions = gatherTemplateContributions(
            projectPath: projectPath,
            pack: pack
        )

        // Only create/update CLAUDE.local.md if there's content to add
        if !allContributions.isEmpty {
            var values: [String: String] = ["REPO_NAME": repoName]
            values.merge(packValues) { _, new in new }
            try writeClaudeLocal(
                at: projectPath,
                contributions: allContributions,
                values: values
            )
        } else {
            output.info("No template sections to add — skipping CLAUDE.local.md")
        }

        // Ensure Serena memories symlink
        ensureSerenaMemoriesSymlink(at: projectPath)

        // Ensure .claude entries exist in user's global gitignore
        try ensureGitignoreEntries()

        // Run pack-specific configuration
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
    func writeClaudeLocal(
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
        let existingContent: String? = fm.fileExists(atPath: claudeLocalPath.path)
            ? try String(contentsOf: claudeLocalPath, encoding: .utf8)
            : nil

        let hasMarkers = existingContent.map {
            !TemplateComposer.parseSections(from: $0).isEmpty
        } ?? false

        if let existingContent, hasMarkers {
            // v2 update path — file has section markers, update in place

            // Warn about unpaired section markers that would prevent safe updates
            let unpaired = TemplateComposer.unpairedSections(in: existingContent)
            if !unpaired.isEmpty {
                output.warn("Unpaired section markers in CLAUDE.local.md: \(unpaired.joined(separator: ", "))")
                output.warn("Sections with missing end markers will not be updated to prevent data loss.")
                output.warn("Add the missing end markers manually, then re-run mcs configure.")
            }

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
            // Compose path — fresh file or v1 migration
            if existingContent != nil {
                output.info("Migrating CLAUDE.local.md from v1 to v2 format")
            }

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

    // MARK: - Serena Memories Symlink

    /// Ensures `.serena/memories` is a symlink to `.claude/memories`.
    /// - If Serena MCP is not installed → skip.
    /// - If `.serena/memories` is already a symlink → skip.
    /// - If `.serena/memories` exists as real directory → copy files, delete, create symlink.
    /// - If `.serena/memories` doesn't exist → create `.serena/` if needed, create symlink.
    private func ensureSerenaMemoriesSymlink(at projectPath: URL) {
        guard CoreTechPack.isSerenaInstalled() else { return }

        let fm = FileManager.default
        let serenaMemories = projectPath
            .appendingPathComponent(Constants.Serena.directory)
            .appendingPathComponent(Constants.Serena.memoriesDirectory)
        let claudeMemories = projectPath
            .appendingPathComponent(Constants.FileNames.claudeDirectory)
            .appendingPathComponent(Constants.Serena.memoriesDirectory)

        // Already a symlink → done
        if let attrs = try? fm.attributesOfItem(atPath: serenaMemories.path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            return
        }

        // Ensure .claude/memories/ exists
        if !fm.fileExists(atPath: claudeMemories.path) {
            do {
                try fm.createDirectory(at: claudeMemories, withIntermediateDirectories: true)
            } catch {
                output.warn("Could not create \(Constants.FileNames.claudeDirectory)/\(Constants.Serena.memoriesDirectory)/: \(error.localizedDescription)")
                return
            }
        }

        // If .serena/memories/ exists as real directory, migrate first
        if fm.fileExists(atPath: serenaMemories.path) {
            output.info("Found \(Constants.Serena.directory)/\(Constants.Serena.memoriesDirectory)/ — migrating to \(Constants.FileNames.claudeDirectory)/\(Constants.Serena.memoriesDirectory)/")
            do {
                let files = try fm.contentsOfDirectory(at: serenaMemories, includingPropertiesForKeys: nil)
                var migrated = 0
                for file in files {
                    let dest = claudeMemories.appendingPathComponent(file.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try fm.copyItem(at: file, to: dest)
                        migrated += 1
                    }
                }
                if migrated > 0 {
                    output.success("Migrated \(migrated) memory file(s)")
                }
                try fm.removeItem(at: serenaMemories)
            } catch {
                output.warn("Memory migration failed: \(error.localizedDescription)")
                return
            }
        }

        // Create .serena/ directory if needed
        let serenaDir = projectPath.appendingPathComponent(Constants.Serena.directory)
        if !fm.fileExists(atPath: serenaDir.path) {
            do {
                try fm.createDirectory(at: serenaDir, withIntermediateDirectories: true)
            } catch {
                output.warn("Could not create \(Constants.Serena.directory)/: \(error.localizedDescription)")
                return
            }
        }

        // Create symlink
        do {
            try fm.createSymbolicLink(at: serenaMemories, withDestinationURL: claudeMemories)
            output.success("Created symlink \(Constants.Serena.directory)/\(Constants.Serena.memoriesDirectory) → \(Constants.FileNames.claudeDirectory)/\(Constants.Serena.memoriesDirectory)")
        } catch {
            output.warn("Could not create symlink: \(error.localizedDescription)")
        }
    }

    // MARK: - Gitignore

    private func ensureGitignoreEntries() throws {
        let manager = GitignoreManager(shell: shell)
        try manager.addCoreEntries()
    }
}
