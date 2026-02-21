import Foundation

/// Shared project configuration logic used by both ConfigureCommand and Installer.
/// Handles template generation, CLAUDE.local.md writing, memory migration,
/// gitignore updates, and pack-specific configuration.
struct ProjectConfigurator {
    let environment: Environment
    let output: CLIOutput
    let shell: ShellRunner

    /// Full interactive configure flow — shows header, pack selection,
    /// branch prefix prompt, runs configure, and shows completion.
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

        output.plain("")
        output.plain("  Your name for branch naming (e.g. bruno \u{2192} bruno/ABC-123-fix-login)")
        let branchPrefix = output.promptInline("Branch prefix", default: "feature")

        try configure(at: projectPath, pack: selectedPack, branchPrefix: branchPrefix)

        output.header("Done")
        output.info("Run 'mcs doctor' to verify configuration")
    }

    /// Configure a project at the given path with the specified pack.
    /// This is the core logic extracted from ConfigureCommand.run().
    func configure(
        at projectPath: URL,
        pack: any TechPack,
        branchPrefix: String
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

        // Prepare template values
        let values: [String: String] = [
            "REPO_NAME": repoName,
            "BRANCH_PREFIX": branchPrefix,
        ]

        // Load core template from resources
        guard let resourceURL = Bundle.module.url(
            forResource: "Resources",
            withExtension: nil
        ) else {
            throw MCSError.fileOperationFailed(
                path: "Resources",
                reason: "Resources bundle not found"
            )
        }

        let coreTemplatePath = resourceURL
            .appendingPathComponent("templates")
            .appendingPathComponent("core")
            .appendingPathComponent("CLAUDE.local.md")
        let coreTemplate = try String(contentsOf: coreTemplatePath, encoding: .utf8)

        // Strip existing markers from the template file
        let strippedCore = coreTemplate
            .replacingOccurrences(
                of: #"<!-- mcs:begin core v[0-9]+\.[0-9]+\.[0-9]+ -->\n"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\n<!-- mcs:end core -->", with: "")
            .replacingOccurrences(of: "<!-- mcs:end core -->\n", with: "")

        // Gather pack template contributions
        let packContributions = pack.templates

        let version = MCSVersion.current
        let claudeLocalPath = projectPath.appendingPathComponent("CLAUDE.local.md")
        let fm = FileManager.default

        // Check if file already exists and preserve user content
        let composed: String
        if fm.fileExists(atPath: claudeLocalPath.path) {
            let existingContent = try String(contentsOf: claudeLocalPath, encoding: .utf8)
            let userContent = TemplateComposer.extractUserContent(from: existingContent)

            // Build fresh sections
            let processedCore = TemplateEngine.substitute(template: strippedCore, values: values)
            var updated = TemplateComposer.replaceSection(
                in: existingContent,
                sectionIdentifier: "core",
                newContent: processedCore,
                newVersion: version
            )

            // Update pack sections
            for contribution in packContributions {
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
                coreContent: strippedCore,
                packContributions: packContributions,
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

        // Memory migration from Serena
        let serenaMemories = projectPath.appendingPathComponent(".serena")
            .appendingPathComponent("memories")
        let newMemories = projectPath.appendingPathComponent(".claude")
            .appendingPathComponent("memories")

        if fm.fileExists(atPath: serenaMemories.path) {
            output.info("Found .serena/memories/ -- migrating to .claude/memories/")

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
        }

        // Add .claude/memories/ to project .gitignore
        let projectGitignore = projectPath.appendingPathComponent(".gitignore")
        if fm.fileExists(atPath: projectGitignore.path) {
            var content = try String(contentsOf: projectGitignore, encoding: .utf8)
            if !content.contains(".claude/memories/") {
                if !content.hasSuffix("\n") { content += "\n" }
                content += ".claude/memories/\n"
                try content.write(to: projectGitignore, atomically: true, encoding: .utf8)
                output.success("Added .claude/memories/ to project .gitignore")
            }
        }

        // Run pack-specific configuration
        let context = ProjectContext(
            projectPath: projectPath,
            branchPrefix: branchPrefix,
            repoName: repoName
        )
        try pack.configureProject(at: projectPath, context: context)
        output.success("Applied \(pack.displayName) configuration")
    }
}
