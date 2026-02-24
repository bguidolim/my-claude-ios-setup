import Foundation

/// Shared utilities for `ProjectConfigurator` and `GlobalConfigurator`.
///
/// Eliminates duplication of common methods that both configurators need.
enum ConfiguratorSupport {
    /// Build a `ComponentExecutor` from the common dependencies.
    static func makeExecutor(
        environment: Environment,
        output: CLIOutput,
        shell: ShellRunner
    ) -> ComponentExecutor {
        ComponentExecutor(
            environment: environment,
            output: output,
            shell: shell
        )
    }

    /// Ensure global gitignore core entries are present.
    static func ensureGitignoreEntries(shell: ShellRunner) throws {
        let manager = GitignoreManager(shell: shell)
        try manager.addCoreEntries()
    }

    /// Validate peer dependencies for all selected packs.
    /// Surfaces registry load errors as warnings instead of silently swallowing them.
    static func validatePeerDependencies(
        packs: [any TechPack],
        environment: Environment,
        output: CLIOutput
    ) -> [PeerDependencyResult] {
        let packRegistryFile = PackRegistryFile(path: environment.packsRegistry)
        let registeredPacks: [PackRegistryFile.PackEntry]
        do {
            registeredPacks = try packRegistryFile.load().packs
        } catch {
            output.warn("Could not read pack registry: \(error.localizedDescription)")
            output.warn("Peer dependency checks may be inaccurate.")
            registeredPacks = []
        }

        return PeerDependencyValidator.validateSelection(
            packs: packs,
            registeredPacks: registeredPacks
        )
    }

    /// Present per-pack component multi-select and return excluded component IDs.
    ///
    /// - Parameter componentsProvider: Extracts the relevant components from a pack.
    ///   `ProjectConfigurator` uses all components; `GlobalConfigurator` filters to global-scope components.
    static func selectComponentExclusions(
        packs: [any TechPack],
        previousState: ProjectState,
        output: CLIOutput,
        componentsProvider: (any TechPack) -> [ComponentDefinition] = { $0.components }
    ) -> [String: Set<String>] {
        var exclusions: [String: Set<String>] = [:]

        for pack in packs {
            let components = componentsProvider(pack)
            guard components.count > 1 else { continue }

            output.plain("")
            output.info("Components for \(pack.displayName):")

            let previousExcluded = previousState.excludedComponents(for: pack.identifier)

            var number = 1
            var items: [SelectableItem] = []
            for component in components {
                items.append(SelectableItem(
                    number: number,
                    name: component.displayName,
                    description: component.description,
                    isSelected: !previousExcluded.contains(component.id)
                ))
                number += 1
            }

            let requiredItems = components
                .filter(\.isRequired)
                .map { RequiredItem(name: $0.displayName) }

            var groups = [SelectableGroup(
                title: pack.displayName,
                items: items,
                requiredItems: requiredItems
            )]

            let selectedNumbers = output.multiSelect(groups: &groups)

            var excluded = Set<String>()
            for (index, component) in components.enumerated() {
                if !selectedNumbers.contains(index + 1) && !component.isRequired {
                    excluded.insert(component.id)
                }
            }

            if !excluded.isEmpty {
                exclusions[pack.identifier] = excluded
            }
        }

        return exclusions
    }
}
