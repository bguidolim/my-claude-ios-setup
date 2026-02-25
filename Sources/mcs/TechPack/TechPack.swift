import Foundation

/// Context provided to tech packs during project configuration
struct ProjectConfigContext: Sendable {
    let projectPath: URL
    let repoName: String
    let output: CLIOutput
    /// Template values resolved by `templateValues(context:)`, available in `configureProject`.
    let resolvedValues: [String: String]
    /// When `true`, project-scoped prompts (e.g. `fileDetect`) should be skipped.
    let isGlobalScope: Bool

    init(
        projectPath: URL,
        repoName: String,
        output: CLIOutput,
        resolvedValues: [String: String] = [:],
        isGlobalScope: Bool = false
    ) {
        self.projectPath = projectPath
        self.repoName = repoName
        self.output = output
        self.resolvedValues = resolvedValues
        self.isGlobalScope = isGlobalScope
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
    /// Section identifiers for template contributions, available without reading
    /// content files from disk. Used for artifact tracking and display.
    var templateSectionIdentifiers: [String] { get }
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
    // NOTE: This default calls `try? templates` which performs disk I/O and silently
    // drops errors. Concrete conformers with throwing `templates` should override this
    // with a lightweight implementation (e.g., ExternalPackAdapter reads from manifest).
    var templateSectionIdentifiers: [String] {
        (try? templates)?.map(\.sectionIdentifier) ?? []
    }
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

