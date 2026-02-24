import Foundation

/// Registry of all available tech packs (compiled-in and external).
/// External packs with the same identifier as a compiled-in pack override it,
/// enabling migration from compiled-in to external packs.
struct TechPackRegistry: Sendable {
    static let shared = TechPackRegistry(packs: [])

    private let compiledPacks: [any TechPack]
    private let externalPacks: [any TechPack]

    init(packs: [any TechPack]) {
        self.compiledPacks = packs
        self.externalPacks = []
    }

    private init(compiledPacks: [any TechPack], externalPacks: [any TechPack]) {
        self.compiledPacks = compiledPacks
        self.externalPacks = externalPacks
    }

    /// Create a registry that includes external packs alongside compiled-in packs.
    /// External packs with the same identifier override compiled-in ones.
    static func withExternalPacks(_ external: [any TechPack]) -> TechPackRegistry {
        TechPackRegistry(
            compiledPacks: [],
            externalPacks: external
        )
    }

    /// All registered packs, with external packs overriding compiled-in ones
    /// when they share the same identifier.
    var availablePacks: [any TechPack] {
        var byID: [String: any TechPack] = [:]
        for pack in compiledPacks {
            byID[pack.identifier] = pack
        }
        for pack in externalPacks {
            byID[pack.identifier] = pack // Override compiled-in
        }
        return Array(byID.values).sorted { $0.identifier < $1.identifier }
    }

    /// Find a pack by identifier (external takes precedence)
    func pack(for identifier: String) -> (any TechPack)? {
        // Check external first (they override compiled-in)
        if let external = externalPacks.first(where: { $0.identifier == identifier }) {
            return external
        }
        return compiledPacks.first { $0.identifier == identifier }
    }

    /// Whether a pack with the given identifier is from an external source.
    func isExternalPack(_ identifier: String) -> Bool {
        externalPacks.contains { $0.identifier == identifier }
    }

    /// Identifiers of all external packs in this registry.
    var externalPackIdentifiers: Set<String> {
        Set(externalPacks.map(\.identifier))
    }

    /// Get all components from all packs
    var allPackComponents: [ComponentDefinition] {
        availablePacks.flatMap { $0.components }
    }

    /// All components (core + pack)
    func allComponents(includingCore coreComponents: [ComponentDefinition]) -> [ComponentDefinition] {
        coreComponents + allPackComponents
    }

    /// Get supplementary doctor checks only for installed packs.
    /// These are pack-level checks that cannot be auto-derived from components.
    func supplementaryDoctorChecks(installedPacks ids: Set<String>) -> [any DoctorCheck] {
        availablePacks.filter { ids.contains($0.identifier) }
            .flatMap { $0.supplementaryDoctorChecks }
    }

    /// Get gitignore entries only for installed packs.
    func gitignoreEntries(installedPacks ids: Set<String>) -> [String] {
        availablePacks.filter { ids.contains($0.identifier) }
            .flatMap { $0.gitignoreEntries }
    }

    /// Get template contributions for a specific pack.
    func templateContributions(for packIdentifier: String) -> [TemplateContribution] {
        (try? pack(for: packIdentifier)?.templates) ?? []
    }

    /// Create a registry that includes external packs loaded from disk.
    /// This is the primary entry point for command-level code that needs
    /// a registry aware of both compiled-in and external packs.
    static func loadWithExternalPacks(
        environment: Environment,
        output: CLIOutput
    ) -> TechPackRegistry {
        let packRegistryFile = PackRegistryFile(path: environment.packsRegistry)
        let loader = ExternalPackLoader(environment: environment, registry: packRegistryFile)
        let adapters = loader.loadAll(output: output)
        if adapters.isEmpty {
            return .shared
        }
        return .withExternalPacks(adapters)
    }
}
