import ArgumentParser
import Foundation

struct ConfigureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "configure",
        abstract: "Generate CLAUDE.local.md for a project"
    )

    @Argument(help: "Path to the project directory (defaults to current directory)")
    var path: String?

    @Option(name: .long, help: "Tech pack to apply (e.g. ios). Can be specified multiple times.")
    var pack: [String] = []

    mutating func run() throws {
        let env = Environment()
        let output = CLIOutput()
        let shell = ShellRunner(environment: env)

        let projectPath: URL
        if let p = path {
            projectPath = URL(fileURLWithPath: p)
        } else {
            projectPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }

        guard FileManager.default.fileExists(atPath: projectPath.path) else {
            throw MCSError.fileOperationFailed(
                path: projectPath.path,
                reason: "Directory does not exist"
            )
        }

        output.header("Configure Project")
        output.info("Project: \(projectPath.path)")

        // Determine which packs to apply:
        // explicit --pack flags take priority, then fall back to installed packs from manifest
        let manifest = Manifest(path: env.setupManifest)
        let packIDs: [String]
        if !pack.isEmpty {
            packIDs = pack
        } else {
            packIDs = manifest.installedPacks.sorted()
        }

        let registry = TechPackRegistry.shared
        let resolvedPacks = packIDs.compactMap { registry.pack(for: $0) }

        if !resolvedPacks.isEmpty {
            output.info("Tech packs: \(resolvedPacks.map(\.displayName).joined(separator: ", "))")
        }

        // Warn about unknown pack names
        for id in packIDs where registry.pack(for: id) == nil {
            output.warn("Unknown tech pack: \(id)")
        }

        // Get branch prefix
        output.plain("  Branch prefix (e.g., 'feature', 'your-name', leave empty to skip):")
        let branchPrefix = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

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

        // Strip existing markers from the template file (they'll be re-added by compose).
        // Use regex to match any version in the marker.
        let strippedCore = coreTemplate
            .replacingOccurrences(
                of: #"<!-- mcs:begin core v[0-9]+\.[0-9]+\.[0-9]+ -->\n"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\n<!-- mcs:end core -->", with: "")
            .replacingOccurrences(of: "<!-- mcs:end core -->\n", with: "")

        // Gather pack contributions from explicitly selected packs
        var packContributions: [TemplateContribution] = []
        for resolvedPack in resolvedPacks {
            packContributions.append(contentsOf: resolvedPack.templates)
        }

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
        _ = try? backup.backupFile(at: claudeLocalPath)
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
        for resolvedPack in resolvedPacks {
            let context = ProjectContext(
                projectPath: projectPath,
                branchPrefix: branchPrefix,
                repoName: repoName
            )
            try resolvedPack.configureProject(at: projectPath, context: context)
            output.success("Applied \(resolvedPack.displayName) configuration")
        }

        output.header("Done")
        output.info("Run 'mcs doctor' to verify configuration")
    }
}
