import Foundation

/// Result of project detection by a tech pack
struct ProjectDetectionResult: Sendable {
    let packIdentifier: String
    let projectName: String
    let projectFile: URL
    let confidence: Double // 0.0...1.0
}

/// Context provided to tech packs during project configuration
struct ProjectContext: Sendable {
    let projectPath: URL
    let branchPrefix: String
    let repoName: String
    let detectionResult: ProjectDetectionResult?
}

/// Template contribution from a tech pack
struct TemplateContribution: Sendable {
    let sectionIdentifier: String // e.g., "ios"
    let version: String // e.g., "1.0.0"
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

/// Protocol that all tech packs must conform to
protocol TechPack: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var description: String { get }
    var components: [ComponentDefinition] { get }
    var templates: [TemplateContribution] { get }
    var hookContributions: [HookContribution] { get }
    var gitignoreEntries: [String] { get }
    var doctorChecks: [any DoctorCheck] { get }
    var migrations: [any PackMigration] { get }

    func detectProject(at path: URL) -> ProjectDetectionResult?
    func configureProject(at path: URL, context: ProjectContext) throws
}

extension TechPack {
    var migrations: [any PackMigration] { [] }
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

/// Protocol for versioned pack migrations.
/// Migrations run in version order during `mcs doctor --fix`.
protocol PackMigration: Sendable {
    /// Short identifier, e.g., "config-yaml-v2".
    var name: String { get }
    /// Version this migration was introduced in, used for ordering.
    var version: String { get }
    /// Human-readable description shown in doctor output.
    var displayName: String { get }
    /// Returns true if this migration still needs to run.
    func isNeeded() -> Bool
    /// Perform the migration. Returns a description of what was done.
    func perform() throws -> String
}
