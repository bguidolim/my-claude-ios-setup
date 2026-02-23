import Foundation

/// Universal tech pack that works with any project regardless of technology.
/// Core components (homebrew, node, plugins, hooks, etc.) remain global —
/// this pack exists to enable `mcs configure` without a tech-specific pack.
struct CoreTechPack: TechPack {
    let identifier = "core"
    let displayName = "Core"
    let description = "Universal Claude Code setup — works with any project"

    // Core components are installed globally via CoreComponents.all, not via this pack.
    let components: [ComponentDefinition] = []
    let hookContributions: [HookContribution] = []
    let gitignoreEntries: [String] = []
    var supplementaryDoctorChecks: [any DoctorCheck] { [] }

    /// Template contributions — conditional based on installed features.
    /// The symlink note is project-specific and handled by ProjectConfigurator,
    /// not here (we don't have the project path in this context).
    var templates: [TemplateContribution] {
        var result: [TemplateContribution] = []

        if Self.isContinuousLearningInstalled() {
            result.append(TemplateContribution(
                sectionIdentifier: "continuous-learning",
                templateContent: CoreTemplates.continuousLearningSection,
                placeholders: ["__REPO_NAME__"]
            ))
        }

        if Self.isSerenaInstalled() {
            result.append(TemplateContribution(
                sectionIdentifier: "serena",
                templateContent: CoreTemplates.serenaSection,
                placeholders: []
            ))
        }

        return result
    }

    func configureProject(at path: URL, context: ProjectConfigContext) throws {
        // No pack-specific project configuration for core.
    }

    // MARK: - Feature Detection

    /// Check whether the continuous learning feature is installed by querying
    /// the manifest — the system's source of truth for installed components.
    static func isContinuousLearningInstalled() -> Bool {
        let env = Environment()
        let manifest = Manifest(path: env.setupManifest)
        return manifest.trackedPaths.contains("hooks/\(Constants.FileNames.continuousLearningHook)")
    }

    /// Check whether Serena MCP server was installed.
    /// Prefers `INSTALLED_COMPONENTS` manifest metadata (present after installs
    /// that include component tracking). Falls back to checking claude.json
    /// for users who installed before component tracking was added.
    static func isSerenaInstalled() -> Bool {
        let env = Environment()
        let manifest = Manifest(path: env.setupManifest)

        if manifest.installedComponents.contains("core.serena") {
            return true
        }

        // Fallback: check claude.json for pre-component-tracking installs
        guard let data = try? Data(contentsOf: env.claudeJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcpServers = json[Constants.JSONKeys.mcpServers] as? [String: Any]
        else {
            return false
        }
        return mcpServers[Constants.Serena.mcpServerName] != nil
    }
}
