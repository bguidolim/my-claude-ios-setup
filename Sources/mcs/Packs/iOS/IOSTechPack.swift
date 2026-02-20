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
            version: "1.0.0",
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

    func detectProject(at path: URL) -> ProjectDetectionResult? {
        IOSProjectDetector.detect(at: path)
    }

    func configureProject(at path: URL, context: ProjectContext) throws {
        // Write .xcodebuildmcp/config.yaml with project-specific values
        let configDir = path.appendingPathComponent(".xcodebuildmcp")
        let configFile = configDir.appendingPathComponent("config.yaml")

        let projectFile: String
        if let detection = context.detectionResult {
            projectFile = detection.projectFile.lastPathComponent
        } else if let detected = IOSProjectDetector.detect(at: path) {
            projectFile = detected.projectFile.lastPathComponent
        } else {
            projectFile = "__PROJECT__"
        }

        let configContent = IOSTemplates.xcodeBuildMCPConfig(projectFile: projectFile)

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try configContent.write(to: configFile, atomically: true, encoding: .utf8)
    }
}
