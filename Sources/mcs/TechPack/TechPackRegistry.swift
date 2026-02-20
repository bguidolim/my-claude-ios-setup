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

    /// Filter packs to only those that were explicitly installed.
    func installedPacks(from manifest: Manifest) -> [any TechPack] {
        let ids = manifest.installedPacks
        return _packs.filter { ids.contains($0.identifier) }
    }

    /// Get doctor checks only for installed packs.
    func doctorChecks(installedPacks ids: Set<String>) -> [any DoctorCheck] {
        _packs.filter { ids.contains($0.identifier) }
            .flatMap { $0.doctorChecks }
    }

    /// Get hook contributions only for installed packs.
    func hookContributions(installedPacks ids: Set<String>) -> [(pack: any TechPack, contribution: HookContribution)] {
        _packs.filter { ids.contains($0.identifier) }
            .flatMap { pack in
                pack.hookContributions.map { (pack: pack, contribution: $0) }
            }
    }

    /// Get migrations only for installed packs, sorted by version.
    func migrations(installedPacks ids: Set<String>) -> [(pack: any TechPack, migration: any PackMigration)] {
        _packs.filter { ids.contains($0.identifier) }
            .flatMap { pack in
                pack.migrations.map { (pack: pack, migration: $0) }
            }.sorted { $0.migration.version < $1.migration.version }
    }

    /// Get gitignore entries only for installed packs.
    func gitignoreEntries(installedPacks ids: Set<String>) -> [String] {
        _packs.filter { ids.contains($0.identifier) }
            .flatMap { $0.gitignoreEntries }
    }

    /// Get template contributions for a specific pack.
    func templateContributions(for packIdentifier: String) -> [TemplateContribution] {
        pack(for: packIdentifier)?.templates ?? []
    }
}
