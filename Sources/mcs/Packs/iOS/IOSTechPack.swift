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
        ".xcodebuildmcp",
    ]

    var doctorChecks: [any DoctorCheck] {
        IOSDoctorChecks.all
    }

    func configureProject(at path: URL, context: ProjectContext) throws {
        // Write .xcodebuildmcp/config.yaml with placeholder for the user to fill in
        let configDir = path.appendingPathComponent(".xcodebuildmcp")
        let configFile = configDir.appendingPathComponent("config.yaml")

        let configContent = IOSTemplates.xcodeBuildMCPConfig(projectFile: "__PROJECT__")

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try configContent.write(to: configFile, atomically: true, encoding: .utf8)
    }
}
