import ArgumentParser
import Foundation

struct ConfigureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "configure",
        abstract: "Generate CLAUDE.local.md for a project"
    )

    @Argument(help: "Path to the project directory (defaults to current directory)")
    var path: String?

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

        // Detect project type
        let detections = TechPackRegistry.shared.detectProject(at: projectPath)
        if let detection = detections.first {
            output.success("Detected \(detection.packIdentifier) project: \(detection.projectName)")
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
        var values: [String: String] = [
            "REPO_NAME": repoName,
            "BRANCH_PREFIX": branchPrefix,
        ]

        // Add project name from detection
        if let detection = detections.first {
            values["PROJECT"] = detection.projectName
        }

        // Load core template from resources
        guard let resourceURL = Bundle.main.url(
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

        // Strip existing markers from the template file (they'll be re-added by compose)
        let strippedCore = coreTemplate
            .replacingOccurrences(of: "<!-- mcs:begin core v2.0.0 -->\n", with: "")
            .replacingOccurrences(of: "\n<!-- mcs:end core -->", with: "")
            .replacingOccurrences(of: "<!-- mcs:end core -->\n", with: "")

        // Gather pack contributions
        var packContributions: [TemplateContribution] = []
        for detection in detections {
            if let pack = TechPackRegistry.shared.pack(for: detection.packIdentifier) {
                packContributions.append(contentsOf: pack.templates)
            }
        }

        let coreVersion = MCS.configuration.version
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
                newVersion: coreVersion
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
                    newVersion: contribution.version
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
                coreVersion: coreVersion,
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
        for detection in detections {
            if let pack = TechPackRegistry.shared.pack(for: detection.packIdentifier) {
                let context = ProjectContext(
                    projectPath: projectPath,
                    branchPrefix: branchPrefix,
                    repoName: repoName,
                    detectionResult: detection
                )
                try pack.configureProject(at: projectPath, context: context)
                output.success("Applied \(pack.displayName) configuration")
            }
        }

        output.header("Done")
        output.info("Run 'mcs doctor' to verify configuration")
    }
}
