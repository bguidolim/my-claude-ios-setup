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

    func configureProject(at path: URL, context: ProjectConfigContext) throws {
        let configDir = path.appendingPathComponent(IOSConstants.FileNames.xcodeBuildMCPDirectory)
        let configFile = configDir.appendingPathComponent("config.yaml")

        // Auto-detect Xcode project file, preferring .xcworkspace over .xcodeproj
        let projectFile = Self.detectXcodeProject(in: path) ?? "__PROJECT__"

        let configContent = IOSTemplates.xcodeBuildMCPConfig(projectFile: projectFile)

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try configContent.write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// Find the first .xcworkspace or .xcodeproj in the directory.
    /// Prefers workspace over project, ignores nested ones (e.g., inside Pods/).
    static func detectXcodeProject(in directory: URL) -> String? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // Prefer workspace (used by CocoaPods, SPM-generated workspaces)
        if let workspace = contents.first(where: { $0.pathExtension == "xcworkspace" }) {
            return workspace.lastPathComponent
        }
        if let project = contents.first(where: { $0.pathExtension == "xcodeproj" }) {
            return project.lastPathComponent
        }
        return nil
    }
}
