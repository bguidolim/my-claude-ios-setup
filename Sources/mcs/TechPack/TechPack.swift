import Foundation

/// Context provided to tech packs during project configuration
struct ProjectConfigContext: Sendable {
    let projectPath: URL
    let repoName: String
    let output: CLIOutput
    /// Template values resolved by `templateValues(context:)`, available in `configureProject`.
    let resolvedValues: [String: String]

    init(projectPath: URL, repoName: String, output: CLIOutput, resolvedValues: [String: String] = [:]) {
        self.projectPath = projectPath
        self.repoName = repoName
        self.output = output
        self.resolvedValues = resolvedValues
    }
}

/// Template contribution from a tech pack
struct TemplateContribution: Sendable {
    let sectionIdentifier: String // e.g., "ios"
    let templateContent: String // The template content with placeholders
    let placeholders: [String] // Required placeholder names (e.g., ["__PROJECT__"])
}

/// Hook contribution from a tech pack
struct HookContribution: Sendable {
    let hookName: String // e.g., "session_start"
    let scriptFragment: String // Bash script fragment to inject
    let position: HookPosition // Where in the hook to inject

    enum HookPosition: Sendable {
        case before // Insert before core hook content
        case after // Insert after core hook content
    }
}

/// Protocol that all tech packs must conform to.
/// Packs are applied to projects via `mcs sync`.
/// Doctor and configure only run pack-specific logic for installed packs.
protocol TechPack: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var description: String { get }
    var components: [ComponentDefinition] { get }
    var templates: [TemplateContribution] { get throws }
    var hookContributions: [HookContribution] { get throws }
    var gitignoreEntries: [String] { get }
    /// Doctor checks that cannot be auto-derived from components.
    /// For pack-level or project-level concerns (e.g. Xcode CLT, config files).
    var supplementaryDoctorChecks: [any DoctorCheck] { get }
    func configureProject(at path: URL, context: ProjectConfigContext) throws

    /// Resolve pack-specific placeholder values for CLAUDE.local.md templates.
    /// Called before template substitution so packs can supply values like `__PROJECT__`.
    func templateValues(context: ProjectConfigContext) throws -> [String: String]
}

extension TechPack {
    func templateValues(context: ProjectConfigContext) -> [String: String] { [:] }
}

/// Protocol for doctor checks (used by both core and packs)
protocol DoctorCheck: Sendable {
    var section: String { get }
    var name: String { get }
    func check() -> CheckResult
    func fix() -> FixResult
}

enum CheckResult: Sendable {
    case pass(String)
    case fail(String)
    case warn(String)
    case skip(String)
}

enum FixResult: Sendable {
    case fixed(String)
    case failed(String)
    case notFixable(String)
}

