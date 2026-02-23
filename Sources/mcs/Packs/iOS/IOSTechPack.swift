import Foundation

/// iOS Development tech pack — provides MCP servers, templates, hooks,
/// and doctor checks for Xcode / iOS simulator workflows.
struct IOSTechPack: TechPack {
    let identifier = "ios"
    let displayName = "iOS Development"
    let description = "MCP servers, templates, and checks for iOS/macOS development with Xcode"

    let components: [ComponentDefinition] = IOSComponents.all

    let templates: [TemplateContribution] = [
        TemplateContribution(
            sectionIdentifier: "ios",
            templateContent: IOSTemplates.claudeLocalSection,
            placeholders: ["__PROJECT__"]
        ),
    ]

    let hookContributions: [HookContribution] = [
        HookContribution(
            hookName: "session_start",
            scriptFragment: IOSHookFragments.simulatorCheck,
            position: .after
        ),
    ]

    let gitignoreEntries: [String] = [
        IOSConstants.FileNames.xcodeBuildMCPDirectory,
    ]

    var supplementaryDoctorChecks: [any DoctorCheck] {
        IOSDoctorChecks.supplementary
    }

    func templateValues(context: ProjectConfigContext) -> [String: String] {
        guard let project = resolveXcodeProject(context: context) else {
            context.output.warn(
                "Skipping iOS template — no Xcode project selected. "
                + "Re-run 'mcs configure --pack ios' to set one."
            )
            return [:]
        }
        return [IOSConstants.TemplateKeys.project: project]
    }

    func configureProject(at path: URL, context: ProjectConfigContext) throws {
        guard let projectFile = context.resolvedValues[IOSConstants.TemplateKeys.project] else {
            // templateValues() already warned the user
            return
        }

        let configDir = path.appendingPathComponent(IOSConstants.FileNames.xcodeBuildMCPDirectory)
        let configFile = configDir.appendingPathComponent("config.yaml")
        let configContent = IOSTemplates.xcodeBuildMCPConfig(projectFile: projectFile)

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try configContent.write(to: configFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Xcode Project Detection

    /// Detect and prompt for Xcode project/workspace selection.
    private func resolveXcodeProject(context: ProjectConfigContext) -> String? {
        let output = context.output
        let projects: [String]
        do {
            projects = try Self.detectXcodeProjects(in: context.projectPath)
        } catch {
            output.warn("Could not read project directory: \(error.localizedDescription)")
            let entered = output.promptInline("Enter project file name (e.g. MyApp.xcodeproj)")
            return entered.isEmpty ? nil : entered
        }

        switch projects.count {
        case 0:
            output.warn("No .xcodeproj or .xcworkspace found in \(context.projectPath.lastPathComponent)")
            let entered = output.promptInline("Enter project file name (e.g. MyApp.xcodeproj)")
            return entered.isEmpty ? nil : entered

        case 1:
            output.info("Found: \(projects[0])")
            return projects[0]

        default:
            let items = projects.map { name -> (name: String, description: String) in
                let ext = (name as NSString).pathExtension
                let desc = ext == "xcworkspace" ? "Workspace" : "Project"
                return (name: name, description: desc)
            }
            let selected = output.singleSelect(
                title: "Multiple Xcode projects found — select one:",
                items: items
            )
            return projects[selected]
        }
    }

    /// Find all .xcworkspace and .xcodeproj files at the top level of a directory.
    /// Results are sorted: workspaces first, then projects, alphabetically within each group.
    /// Throws if the directory cannot be read (permissions, missing path, I/O error).
    static func detectXcodeProjects(in directory: URL) throws -> [String] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let workspaces = contents
            .filter { $0.pathExtension == "xcworkspace" }
            .map(\.lastPathComponent)
            .sorted()
        let projects = contents
            .filter { $0.pathExtension == "xcodeproj" }
            .map(\.lastPathComponent)
            .sorted()

        return workspaces + projects
    }
}
