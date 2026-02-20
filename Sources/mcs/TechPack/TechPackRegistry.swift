import Foundation

/// Registry of all available tech packs
final class TechPackRegistry: @unchecked Sendable {
    static let shared: TechPackRegistry = {
        let registry = TechPackRegistry()
        registry.register(IOSTechPack())
        return registry
    }()

    private var _packs: [any TechPack] = []

    private init() {}

    /// Register a tech pack
    func register(_ pack: any TechPack) {
        _packs.append(pack)
    }

    /// All registered packs
    var availablePacks: [any TechPack] { _packs }

    /// Find a pack by identifier
    func pack(for identifier: String) -> (any TechPack)? {
        _packs.first { $0.identifier == identifier }
    }

    /// Get all components from all packs
    var allPackComponents: [ComponentDefinition] {
        _packs.flatMap { $0.components }
    }

    /// All components (core + pack)
    func allComponents(includingCore coreComponents: [ComponentDefinition]) -> [ComponentDefinition] {
        coreComponents + allPackComponents
    }

    /// Detect project type at a path
    func detectProject(at path: URL) -> [ProjectDetectionResult] {
        _packs.compactMap { $0.detectProject(at: path) }
            .sorted { $0.confidence > $1.confidence }
    }

    /// Get all doctor checks from all packs
    var allPackDoctorChecks: [any DoctorCheck] {
        _packs.flatMap { $0.doctorChecks }
    }

    /// Get all gitignore entries from all packs
    var allPackGitignoreEntries: [String] {
        _packs.flatMap { $0.gitignoreEntries }
    }

    /// Get template contributions for a specific pack
    func templateContributions(for packIdentifier: String) -> [TemplateContribution] {
        pack(for: packIdentifier)?.templates ?? []
    }

    /// Get all hook contributions from all packs
    var allPackHookContributions: [(pack: any TechPack, contribution: HookContribution)] {
        _packs.flatMap { pack in
            pack.hookContributions.map { (pack: pack, contribution: $0) }
        }
    }

    /// Get all migrations from all packs, sorted by version
    var allPackMigrations: [(pack: any TechPack, migration: any PackMigration)] {
        _packs.flatMap { pack in
            pack.migrations.map { (pack: pack, migration: $0) }
        }.sorted { $0.migration.version < $1.migration.version }
    }
}
