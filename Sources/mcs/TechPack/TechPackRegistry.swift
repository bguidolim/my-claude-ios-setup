import Foundation

/// Registry of all available tech packs.
/// Immutable after initialization — all packs are compiled-in.
struct TechPackRegistry: Sendable {
    static let shared = TechPackRegistry(packs: [CoreTechPack(), IOSTechPack()])

    private let packs: [any TechPack]

    init(packs: [any TechPack]) {
        self.packs = packs
    }

    /// All registered packs
    var availablePacks: [any TechPack] { packs }

    /// Find a pack by identifier
    func pack(for identifier: String) -> (any TechPack)? {
        packs.first { $0.identifier == identifier }
    }

    /// Get all components from all packs
    var allPackComponents: [ComponentDefinition] {
        packs.flatMap { $0.components }
    }

    /// All components (core + pack)
    func allComponents(includingCore coreComponents: [ComponentDefinition]) -> [ComponentDefinition] {
        coreComponents + allPackComponents
    }

    /// Filter packs to only those that were explicitly installed.
    func installedPacks(from manifest: Manifest) -> [any TechPack] {
        let ids = manifest.installedPacks
        return packs.filter { ids.contains($0.identifier) }
    }

    /// Get supplementary doctor checks only for installed packs.
    /// These are pack-level checks that cannot be auto-derived from components.
    func supplementaryDoctorChecks(installedPacks ids: Set<String>) -> [any DoctorCheck] {
        packs.filter { ids.contains($0.identifier) }
            .flatMap { $0.supplementaryDoctorChecks }
    }

    /// Get hook contributions only for installed packs.
    func hookContributions(installedPacks ids: Set<String>) -> [(pack: any TechPack, contribution: HookContribution)] {
        packs.filter { ids.contains($0.identifier) }
            .flatMap { pack in
                pack.hookContributions.map { (pack: pack, contribution: $0) }
            }
    }

    /// Get migrations only for installed packs, sorted by version.
    func migrations(installedPacks ids: Set<String>) -> [(pack: any TechPack, migration: any PackMigration)] {
        packs.filter { ids.contains($0.identifier) }
            .flatMap { pack in
                pack.migrations.map { (pack: pack, migration: $0) }
            }.sorted { $0.migration.version < $1.migration.version }
    }

    /// Get gitignore entries only for installed packs.
    func gitignoreEntries(installedPacks ids: Set<String>) -> [String] {
        packs.filter { ids.contains($0.identifier) }
            .flatMap { $0.gitignoreEntries }
    }

    /// Get template contributions for a specific pack.
    func templateContributions(for packIdentifier: String) -> [TemplateContribution] {
        pack(for: packIdentifier)?.templates ?? []
    }
}
